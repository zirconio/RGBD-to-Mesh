#include "Device.h"

/*
#define FOV_Y 43 # degrees
#define FOV_X 57

#define SCALE_Y tan((FOV_Y/2)*pi/180)
#define SCALE_X tan((FOV_X/2)*pi/180)
*/
#define SCALE_Y 0.393910475614942392
#define SCALE_X 0.542955699638436879
#define PI      3.141592653589793238

ColorPixel* dev_colorImageBuffer;
DPixel* dev_depthImageBuffer;
PointCloud* dev_pointCloudBuffer;

int cuImageWidth = 0;
int	cuImageHeight = 0;

GLuint imagePBO = (GLuint)NULL;

void checkCUDAError(const char *msg) {
	cudaError_t err = cudaGetLastError();
	if( cudaSuccess != err) {
		fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString( err) ); 
		exit(EXIT_FAILURE); 
	}
} 



__global__ void makePointCloud(ColorPixel* colorPixels, DPixel* dPixels, int xRes, int yRes, PointCloud* pointCloud) {
	int i = (blockIdx.y*gridDim.x + blockIdx.x)*(blockDim.y*blockDim.x) + (threadIdx.y*blockDim.x) + threadIdx.x;
	int r = i / xRes;
	int c = i % xRes;

	if (dPixels[i].depth > 0.0f) {
		float u = (c - (xRes-1)/2.0f + 1) / (xRes-1); // image plane u coordinate
		float v = ((yRes-1)/2.0f - r) / (yRes-1); // image plane v coordinate
		float Z = dPixels[i].depth/1000.0f; // depth in mm
		pointCloud[i].pos = glm::vec3(u*Z*SCALE_X, v*Z*SCALE_Y, Z); // convert uv to XYZ
		pointCloud[i].color = glm::vec3(colorPixels[i].r, colorPixels[i].g, colorPixels[i].b); // copy over texture
	}
}

__device__ EigenResult eigenSymmetric33(glm::mat3 A) {
	// Given a real symmetric 3x3 matrix A, computes the eigenvalues and eigenvectors
	EigenResult result;
	// Compute eigenvalues
	// see: http://en.wikipedia.org/wiki/Eigenvalue_algorithm#3.C3.973_matrices
	float p1 = pow(A[0][1], 2) + pow(A[0][2], 2) + pow(A[1][2], 2);
	if (p1 == 0) { // A is diagonal
		result.eigenVals = glm::vec3(A[0][0], A[1][1], A[2][2]);
	} else {
		float q = (A[0][0] + A[1][1] + A[2][2])/3.0f; // mean(trace(A))
		float p2 = pow(A[0][0]-q, 2) + pow(A[1][1]-q, 2) + pow(A[2][2]-q, 2) + 2*p1;
		float p = sqrt(p2/6);
		glm::mat3 B = (1/p) * (A-q*glm::mat3(1.0f));
		float r = glm::determinant(B)/2;
		// theoretically -1 <= r <= 1, but clamp in case of numeric error
		float phi;
		if (r <= -1) {
			phi = PI / 3;
		} else if (r >= 1) {
			phi = 0;
		} else {
			phi = glm::acos(r)/3;
		}
		result.eigenVals.x = q + 2*p*glm::cos(phi);
		result.eigenVals.z = q + 2*p*glm::cos(phi + 2*PI/3);
		result.eigenVals.y = 3*q - result.eigenVals.x - result.eigenVals.z;
	}
	// Compute eigenvectors
	//glm::vec3 eigVec1 = glm::cross(A[0] - glm::vec3(0.0f, result.eigenVals[0], 0.0f
	// TODO: refactor to impose condition on smallest eigenvalue and just return normal vector
}

__global__ void computePointNormals(PointCloud* pointCloud, int xRes, int yRes) {
	int i = (blockIdx.y*gridDim.x + blockIdx.x)*(blockDim.y*blockDim.x) + (threadIdx.y*blockDim.x) + threadIdx.x;
	int r = i / xRes;
	int c = i % xRes;

}


//Kernel that writes the depth image to the OpenGL PBO directly.
__global__ void sendDepthImageBufferToPBO(float4* PBOpos, glm::vec2 resolution, DPixel* depthBuffer){

	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = x + (y * resolution.x);

	if(x<resolution.x && y<resolution.y){

		//Cast to float for storage
		float depth = depthBuffer[index].depth;

		// Each thread writes one pixel location in the texture (textel)
		//Store depth in every component except alpha
		PBOpos[index].x = depth;
		PBOpos[index].y = depth;
		PBOpos[index].z = depth;
		PBOpos[index].w = 1.0f;
	}
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendColorImageBufferToPBO(float4* PBOpos, glm::vec2 resolution, ColorPixel* colorBuffer){

	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = x + (y * resolution.x);

	if(x<resolution.x && y<resolution.y){

		glm::vec3 color;
		color.r = colorBuffer[index].r/255.0f;
		color.g = colorBuffer[index].g/255.0f;
		color.b = colorBuffer[index].b/255.0f;


		// Each thread writes one pixel location in the texture (textel)
		PBOpos[index].x = color.r;
		PBOpos[index].y = color.g;
		PBOpos[index].z = color.b;
		PBOpos[index].w = 1.0f;
	}
}

void initImagePBO(GLuint *pbo)
{
	if (pbo) {
		// set up vertex data parameter
		int num_texels = cuImageWidth*cuImageHeight;
		int num_values = num_texels * 4;
		int size_tex_data = sizeof(GLfloat) * num_values;

		// Generate a buffer ID called a PBO (Pixel Buffer Object)
		glGenBuffers(1,pbo);
		// Make this the current UNPACK buffer (OpenGL is state-based)
		glBindBuffer(GL_PIXEL_UNPACK_BUFFER, *pbo);
		// Allocate data for the buffer. 4-channel float image
		glBufferData(GL_PIXEL_UNPACK_BUFFER, size_tex_data, NULL, GL_DYNAMIC_COPY);
		cudaGLRegisterBufferObject( *pbo );
	}
}


//Intialize pipeline buffers
void initCuda(int width, int height)
{
	//Allocate buffers
	cudaMalloc((void**) &dev_colorImageBuffer, sizeof(ColorPixel)*width*height);
	cudaMalloc((void**) &dev_depthImageBuffer, sizeof(DPixel)*width*height);
	cudaMalloc((void**) &dev_pointCloudBuffer, sizeof(PointCloud)*width*height);
	cuImageWidth = width;
	cuImageHeight = height;

	
	initImagePBO(&imagePBO);


}

//Free all allocated buffers and close out environment
void cleanupCuda()
{
	cudaFree(dev_colorImageBuffer);
	cudaFree(dev_depthImageBuffer);
	cudaFree(dev_pointCloudBuffer);
	cuImageWidth = 0;
	cuImageHeight = 0;
	
	cudaDeviceReset();
}


//Copies a depth image to the GPU buffer. 
//Returns false if width and height do not match buffer size set by initCuda(), true if success
bool pushDepthArrayToBuffer(DPixel* hDepthArray, int width, int height)
{
	if(width != cuImageWidth || height != cuImageHeight)
		return false;//Buffer wrong size

	cudaMemcpy(dev_depthImageBuffer, hDepthArray, sizeof(DPixel)*width*height, cudaMemcpyHostToDevice);
	return true;
}


//Copies a color image to the GPU buffer. 
//Returns false if width and height do not match buffer size set by initCuda(), true if success
bool pushColorArrayToBuffer(ColorPixel* hColorArray, int width, int height)
{
	if(width != cuImageWidth || height != cuImageHeight)
		return false;//Buffer wrong size

	cudaMemcpy((void*)dev_colorImageBuffer, hColorArray, sizeof(ColorPixel)*width*height, cudaMemcpyHostToDevice);
	return true;
}

//Converts the color and depth images currently in GPU buffers into point cloud buffer
void convertToPointCloud()
{
	//TODO: Implement

}

//Computes normals for point cloud in buffer and writes back to the point cloud buffer.
void computePointCloudNormals()
{
	//TODO: Implement

}


//Draws depth image buffer to the texture.
//Texture width and height must match the resolution of the depth image.
//Returns false if width or height does not match, true otherwise
bool drawDepthImageBufferToTexture(GLuint texture, int texWidth, int texHeight)
{
	//TODO: Implement
	return false;
}

//Draws color image buffer to the texture.
//Texture width and height must match the resolution of the color image.
//Returns false if width or height does not match, true otherwise
bool drawColorImageBufferToTexture(GLuint texture, int texWidth, int texHeight)
{
	if(texWidth != cuImageWidth || texHeight != cuImageHeight)
		return false;

	glBindTexture(GL_TEXTURE_2D, texture);
	//TODO: Fix. Cannot copy from CUDA memory.
	//glTexImage2D( GL_TEXTURE_2D, 0, GL_RGBA32F, texWidth, texHeight, 0, GL_RGB, GL_UNSIGNED_BYTE, dev_colorImageBuffer);
	glBindTexture(GL_TEXTURE_2D, 0);
	return true;
}

//Renders the point cloud as stored in the VBO to the texture
void drawPointCloudVBOToTexture(GLuint texture, int texWidth, int texHeight /*TODO: More vizualization parameters here*/)
{
	//TODO: Implement

}

//Renders various debug information about the 2D point cloud buffer to the texture.
//Texture width and height must match the resolution of the point cloud buffer.
//Returns false if width or height does not match, true otherwise
bool drawPointCloudDebugToTexture(GLuint texture, int texWidth, int texHeight /*TODO: More vizualization parameters here*/)
{
	//TODO: Implement
	return false;
}