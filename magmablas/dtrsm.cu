/*
    -- MAGMA (version 0.1) --
	Univ. of Tennessee, Knoxville
	Univ. of California, Berkeley
	Univ. of Colorado, Denver
	June 2009
*/

#include "cublas.h"
#include "magma.h"
#include <stdio.h>

#define BLOCK_SIZE 16

__global__ void
strmm_kernel (int M, int N, double *A, int lda, double *x, int ldx)
{
	int i, k;
	int inb;
	int tyb;
	double Ystx=0;
	double *Ast, *At, *Xst;

	// Thread index
	int tx = threadIdx.x;
	int ty = threadIdx.y;
	int bx = blockIdx.x;
	int bmx = blockDim.y;

	__shared__ double As[BLOCK_SIZE*BLOCK_SIZE];
	__shared__ double Xs[BLOCK_SIZE*512/BLOCK_SIZE];


	tyb = ty*BLOCK_SIZE;
	Xst = Xs+tyb;
	Ast = As+tyb+tx;
	At = A+ty*lda+tx;

	inb = bmx;

	// load A
	#pragma unroll
	for (i=0; i<(M/inb); i++)
		Ast[i*BLOCK_SIZE*inb] = At[i*inb*lda];
	
	for (k=0; k<N; k+=bmx)
	{
		// load b and x
		Xst[tx] = x[bx*ldx*N+(k+ty)*ldx+tx];

		// Synchronize to make sure the matrices are loaded
		__syncthreads();

		for (i=0; i<=BLOCK_SIZE; i++)
			if (tx >=i)
				Ystx += As[i*BLOCK_SIZE+tx]*Xs[tyb+i];

		// write back y
		x[bx*ldx*N+(k+ty)*ldx+tx] = Ystx;
		Ystx = 0;
	}
}



__global__ void
diag_strtri_kernel (char uplo, char diag, double *A, double *d_dinvA, int lda)
{
	int i,j;
	double Ystx=0;
	double *Bw=NULL, *x=NULL, *y=NULL, *Aoff=NULL;
	double *my_d_dinvA;

	// Thread index
	int tx = threadIdx.x;
	int txw;

	// Block index
	int bx = blockIdx.x;
		
	Aoff = A+bx*lda*BLOCK_SIZE+bx*BLOCK_SIZE;
	my_d_dinvA = d_dinvA+bx*BLOCK_SIZE*BLOCK_SIZE;

	__shared__ double As[BLOCK_SIZE*BLOCK_SIZE];
	__shared__ double Bs[BLOCK_SIZE*BLOCK_SIZE];

	// load A
	#pragma unroll
	for (i=0; i<BLOCK_SIZE; i++)
           // read in the whole square block of my A
	   Bs[i*BLOCK_SIZE+tx] = As[i*BLOCK_SIZE+tx] = *(Aoff+i*lda+tx);
	
        // not the upper or lower diagonal	
	// Synchronize to make sure the matrices are loaded
	__syncthreads();

	Bs[tx*BLOCK_SIZE+tx] = ((diag=='u' || diag=='U')?1:(1/As[tx*BLOCK_SIZE+tx]));

	if (uplo == 'l' || uplo == 'L')
	{
		/*
		 * the lower case
		 */
		for (i=BLOCK_SIZE-2; i>=0; i--)
		{
			Ystx = 0;
			if (tx>i)
			{
				//strmv
				Bw = Bs+(i+1)*BLOCK_SIZE+i+1;
				x = As+i*BLOCK_SIZE+i+1;
				y = Bs+i*BLOCK_SIZE+i+1;

				txw = tx-i-1;
				#pragma unroll
				for (j=0; j<txw+1; j++)
					Ystx += *(Bw+j*BLOCK_SIZE+txw)*x[j];

				//sscal
				y[txw] = Ystx*(-Bs[i*BLOCK_SIZE+i]);
			}
			__syncthreads();
		}

	}
	else
	{
		/*
		 * the upper case
		 */
		for (i=0; i<BLOCK_SIZE; i++)
		{
			Ystx = 0;
			if (tx<i)
			{
				//strmv
				x = As+i*BLOCK_SIZE;
				y = Bs+i*BLOCK_SIZE;

				#pragma unroll
				for (j=tx; j<i; j++)
					Ystx += *(Bs+j*BLOCK_SIZE+tx)*x[j];

				//sscal
				y[tx] = Ystx*(-Bs[i*BLOCK_SIZE+i]);
			}
			__syncthreads();
		}


	}
		
	// write back A
	#pragma unroll
	for (i=0; i<BLOCK_SIZE; i++)
		*(my_d_dinvA+i*BLOCK_SIZE+tx) = Bs[i*BLOCK_SIZE+tx];
}

#define NUM_OF_SM 30 


extern "C" void
magmablas_dtrsm1(char side, char uplo, char tran, char diag, 
                int M, int N, double* A, int lda, double* b, int ldb)
{
    int i, nblocks;
    dim3 dimBlock;
    double *d_dinvA;

    if ((M%BLOCK_SIZE) != 0)
	{
	  printf ("warning: M=%d not divisable by BLOCK_SIZE=%d\n", M, BLOCK_SIZE);
	  exit(0);
	}

    if (side == 'l' || side == 'L')
	{
          /* inverse the diagonals
	   * Allocate device memory for the inversed diagonal blocks, size=m*BLOCK_SIZE 
	   */
	  cudaMalloc((void**)&d_dinvA, BLOCK_SIZE*M*sizeof(double));
	  nblocks = M/BLOCK_SIZE;
	  diag_strtri_kernel<<<nblocks, BLOCK_SIZE>>>(uplo, diag, A, d_dinvA, lda);

	  if (tran == 'N' || tran == 'n')
	  /* the non-transpose case */
	  {
		if (uplo == 'L' || uplo == 'l')
		{
		/* the lower case */
  		   for (i=0; i<M; i+=BLOCK_SIZE)
			{
			  cublasDtrmm ('L', 'L', 'N', diag, BLOCK_SIZE, N, 1.0, 
                                        d_dinvA+i*BLOCK_SIZE, BLOCK_SIZE, b+i, ldb);
			  if (i+BLOCK_SIZE>=M)
			     break;

			  cublasDgemm ('N', 'N', M-i-BLOCK_SIZE, N, BLOCK_SIZE, -1.0, 
                                    A+i*lda+i+BLOCK_SIZE, lda, b+i, ldb, 1.0, b+i+BLOCK_SIZE, ldb);
			}
		}
		else
		{
		   /* the upper case */
		   for (i=M-BLOCK_SIZE; i>=0; i-=BLOCK_SIZE)
			{
			  cublasDtrmm ('L', 'U', 'N', diag, BLOCK_SIZE, N, 1.0, 
                                       d_dinvA+i*BLOCK_SIZE, BLOCK_SIZE, b+i, ldb);

			  if (i-BLOCK_SIZE<0)
			    break;

		 	  cublasDgemm ('N', 'N', i, N, BLOCK_SIZE, -1.0, A+i*lda, 
                                       lda, b+i, ldb, 1.0, b, ldb);
			}
		}
		}
		else
		/* the transpose case */
		{
		  if (uplo == 'L' || uplo == 'l')
			{
			/* the lower case */
			for (i=M-BLOCK_SIZE; i>=0; i-=BLOCK_SIZE)
			{
			  cublasDtrmm (side, uplo, tran, diag, BLOCK_SIZE, N, 1.0, 
                                       d_dinvA+i*BLOCK_SIZE, BLOCK_SIZE, b+i, ldb);

			  if (i-BLOCK_SIZE<0)
				break;

			  cublasDgemm ('T', 'N', i, N, BLOCK_SIZE, -1.0, A+i, lda, b+i, 
                                       ldb, 1.0, b, ldb);
			}
		}
		else
		{
		/* the upper case */
		for (i=0; i<M; i+=BLOCK_SIZE)
		  {
		     cublasDtrmm (side, uplo, tran, diag, BLOCK_SIZE, N, 1.0, 
                                  d_dinvA+i*BLOCK_SIZE, BLOCK_SIZE, b+i, ldb);

		     if (i+BLOCK_SIZE>=M)
			break;

		     cublasDgemm ('T', 'N', M-i-BLOCK_SIZE, N, BLOCK_SIZE, 
                            -1.0, A+(i+BLOCK_SIZE)*lda+i, lda, b+i, ldb, 1.0, b+i+BLOCK_SIZE, ldb);
		   }
		}
	}
      }
      else
      {
	/* inverse the diagonals
	 * Allocate device memory for the inversed diagonal blocks, size=m*BLOCK_SIZE 
	 */
	cudaMalloc((void**)&d_dinvA, BLOCK_SIZE*N*sizeof(double));
	nblocks = N/BLOCK_SIZE;
	diag_strtri_kernel<<<nblocks, BLOCK_SIZE>>>(uplo, diag, A, d_dinvA, lda);

	if (tran == 'N' || tran == 'n')
	/* the non-transpose case */
	{
	   if (uplo == 'L' || uplo == 'l')
		{
		/* the lower case */
		for (i=N-BLOCK_SIZE; i>=0; i-=BLOCK_SIZE)
		   {
			cublasDtrmm ('R', 'L', 'N', diag, M, BLOCK_SIZE, 1.0, 
                                     d_dinvA+i*BLOCK_SIZE, BLOCK_SIZE, b+ldb*i, ldb);

			if (i-BLOCK_SIZE<0)
 		 	   break;

			cublasDgemm ('N', 'N', M, i, BLOCK_SIZE, -1.0, b+ldb*i, ldb, 
                                     A+i, lda, 1.0, b, ldb);
		   }
		}
		else
		{
		  /* the upper case */
		  for (i=0; i<N; i+=BLOCK_SIZE)
			{
			   cublasDtrmm ('R', 'U', 'N', diag, M, BLOCK_SIZE, 1.0, 
                                         d_dinvA+i*BLOCK_SIZE, BLOCK_SIZE, b+ldb*i, ldb);

			   if (i+BLOCK_SIZE>=N)
				break;

			   cublasDgemm ('N', 'N', M, N-i-BLOCK_SIZE, BLOCK_SIZE, -1.0, b+i*ldb, 
                                 ldb, A+(i+BLOCK_SIZE)*lda+i, lda, 1.0, b+(i+BLOCK_SIZE)*ldb, ldb);
			}
		}
	}
	else
	/* the transpose case */
	{
	   if (uplo == 'L' || uplo == 'l')
	   {
		  /* the lower case */
		  for (i=0; i<N; i+=BLOCK_SIZE)
		     {
			cublasDtrmm ('R', 'L', 'T', diag, M, BLOCK_SIZE, 1.0, 
                                     d_dinvA+i*BLOCK_SIZE, BLOCK_SIZE, b+ldb*i, ldb);

			if (i+BLOCK_SIZE>=N)
			  break;

			cublasDgemm ('N', 'T', M, N-i-BLOCK_SIZE, BLOCK_SIZE, -1.0, b+ldb*i, 
                                   ldb, A+i*lda+BLOCK_SIZE+i, lda, 1.0, b+(i+BLOCK_SIZE)*ldb, ldb);
		      }
	   }
	   else
	   {
		/* the upper case */
		for (i=N-BLOCK_SIZE; i>=0; i-=BLOCK_SIZE)
		{
		   cublasDtrmm ('R', 'U', 'T', diag, M, BLOCK_SIZE, 1.0, 
                                d_dinvA+i*BLOCK_SIZE, BLOCK_SIZE, b+ldb*i, ldb);

		   if (i-BLOCK_SIZE<0)
			break;

       		   cublasDgemm ('N', 'T', M, i, BLOCK_SIZE, -1.0, b+i*ldb, ldb, 
                                A+i*lda, lda, 1.0, b, ldb);
		}
	   }
	}
   }
   cudaFree(d_dinvA);
}

#undef BLOCK_SIZE
