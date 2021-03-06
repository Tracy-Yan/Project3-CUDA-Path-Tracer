#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <thrust/count.h>
#include <thrust/device_ptr.h>
#include <thrust/sort.h>
#include <thrust/partition.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "glm/gtc/random.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"
#include "glm/gtx/normal.hpp"

#define ERRORCHECK 1
#define SORTBYMAT 0
#define CACHE 0
#define DEPTH_OF_FIELD 0
#define USE_OCTREE 0

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char *msg, const char *file, int line) {
#if ERRORCHECK
    cudaDeviceSynchronize();
    cudaError_t err = cudaGetLastError();
    if (cudaSuccess == err) {
        return;
    }

    fprintf(stderr, "CUDA error");
    if (file) {
        fprintf(stderr, " (%s:%d)", file, line);
    }
    fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
    getchar();
#  endif
    exit(EXIT_FAILURE);
#endif
}

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
    int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
    return thrust::default_random_engine(h);
}



//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
        int iter, glm::vec3* image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < resolution.x && y < resolution.y) {
        int index = x + (y * resolution.x);
        glm::vec3 pix = image[index];

        glm::ivec3 color;
        color.x = glm::clamp((int) (pix.x / iter * 255.0), 0, 255);
        color.y = glm::clamp((int) (pix.y / iter * 255.0), 0, 255);
        color.z = glm::clamp((int) (pix.z / iter * 255.0), 0, 255);

        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

static Scene * hst_scene = NULL;
static glm::vec3 * dev_image = NULL;
static Geom * dev_geoms = NULL;
static Material * dev_materials = NULL;
static PathSegment * dev_paths = NULL;
static ShadeableIntersection * dev_intersections = NULL;
// TODO: static variables for device memory, any extra info you need, etc
// ...
static int *dev_path_idxes = NULL;
static int *dev_path_mats = NULL;
static ShadeableIntersection *dev_intersections_cache = NULL;
static bool state_updated = true;
static OctreeNode *dev_octree = NULL;
static int *dev_geom_idxes = NULL;

// Predicate for thust__remove_if
struct path_is_end {
	__host__ __device__ bool operator()(int idx) {
		return idx < 0;
	}
};

struct bounce_end {
	__host__ __device__ bool operator()(const PathSegment& seg) {
		return seg.remainingBounces >= 0;
	}
};

struct sort_by_mat {
	__host__ __device__ bool operator()(const ShadeableIntersection& ins1, const ShadeableIntersection& ins2) {
		return ins1.materialId > ins2.materialId;
	}
};

void pathtraceInit(Scene *scene) {
    hst_scene = scene;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

    cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

  	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

  	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
  	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

  	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
  	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

  	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
  	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

    // TODO: initialize any extra device memeory you need
	cudaMalloc(&dev_path_idxes, pixelcount * sizeof(int));
	cudaMemset(dev_path_idxes, 0, pixelcount * sizeof(int));

	cudaMalloc(&dev_path_mats, pixelcount * sizeof(int));
	cudaMemset(dev_path_mats, 0, pixelcount * sizeof(int));

	cudaMalloc(&dev_intersections_cache, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections_cache, 0, pixelcount * sizeof(ShadeableIntersection));

	state_updated = true;

	cudaMalloc(&dev_octree, scene->octree.size() * sizeof(OctreeNode));
	cudaMemcpy(dev_octree, scene->octree.data(), scene->octree.size() * sizeof(OctreeNode), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_geom_idxes, scene->geom_indices.size() * sizeof(int));
	cudaMemcpy(dev_geom_idxes, scene->geom_indices.data(), scene->geom_indices.size() * sizeof(int), cudaMemcpyHostToDevice);

    checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
    cudaFree(dev_image);  // no-op if dev_image is null
  	cudaFree(dev_paths);
  	cudaFree(dev_geoms);
  	cudaFree(dev_materials);
  	cudaFree(dev_intersections);
    // TODO: clean up any extra device memory you created
	cudaFree(dev_path_idxes);
	cudaFree(dev_path_mats);
	cudaFree(dev_octree);
	cudaFree(dev_geom_idxes);

    checkCUDAError("pathtraceFree");
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment & segment = pathSegments[index];

		segment.ray.origin = cam.position;
    segment.color = glm::vec3(1.0f, 1.0f, 1.0f);

		// TODO: implement antialiasing by jittering the ray
	// gaussian sampling for aperture simulation
#if DEPTH_OF_FIELD
	thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, 0);
	thrust::random::normal_distribution<float> r_r(0.0f, 5 * cam.pixelLength.x);
	thrust::random::normal_distribution<float> r_u(0.0f, 5 * cam.pixelLength.y);

	segment.ray.direction = glm::normalize(cam.view
		- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
		- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f)
		- r_r(rng) * cam.right - r_u(rng) * cam.up
			);
#else
	// original
	segment.ray.direction = glm::normalize(cam.view
		- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
		- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f)
	);
#endif
		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
	}
}

__global__ void fillPathSegmentPtrs(int num_paths, PathSegment *pathSegments, PathSegment **pathSegmentPtrs) {
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths) {
		pathSegmentPtrs[idx] = &pathSegments[idx];
	}
}

__global__ void fillPathIndexes(int num_paths, int *pathIndexes) {
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths) {
		pathIndexes[idx] = idx;
	}
}
// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment *pathSegments
	, Geom * geoms
	, int geoms_size
	, ShadeableIntersection * intersections
	, ShadeableIntersection * cached_intersections
	, bool state_changed
	, int num_nodes
	, OctreeNode *octree_nodes
	, int *geom_indices
	)
{
	int index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index >= num_paths) {
		return;

	}
#if CACHE
	if (depth == 0 && !state_changed) {
		// first intersection, use cache
		intersections[index] = cached_intersections[index];
		return;
	}
#endif

	//int path_index = pathIndexes[index];
	int path_index = index;
	PathSegment pathSegment = pathSegments[path_index];

	float t;
	glm::vec3 intersect_point;
	glm::vec3 normal;
	float t_min = FLT_MAX;
	int hit_geom_index = -1;
	bool outside = true;

	glm::vec3 tmp_intersect;
	glm::vec3 tmp_normal;

	// naive parse through global geoms

	for (int i = 0; i < geoms_size; i++)
	{
		Geom & geom = geoms[i];

		if (geom.type == CUBE)
		{
			t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
		}
		else if (geom.type == SPHERE)
		{
			t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
		}

		else if (geom.type == TRIANGLE) {
#ifdef USE_OCTREE
			break;
#else
			glm::vec3 baryRes;
			bool ret = glm::intersectRayTriangle(pathSegment.ray.origin, pathSegment.ray.direction,
				geom.v0, geom.v1, geom.v2, baryRes);
			if (ret) {
				// Intersect
				tmp_normal = geom.normal;
				tmp_intersect = geom.v0 * baryRes.x + geom.v1 * baryRes.y + geom.v2 * (1 - baryRes.x - baryRes.y);
				t = baryRes.z;
				if (glm::dot(pathSegment.ray.origin, tmp_normal) > 0.0f) {
					outside = false;
					tmp_normal = -tmp_normal;
				}
			}
			else {
				// No intersection
				t = -1.0f;
			}
#endif
		}

		// TODO: add more intersection tests here... triangle? metaball? CSG?

		// Compute the minimum t from the intersection tests to determine what
		// scene geometry object was hit first.
		if (t > 0.0f && t_min > t)
		{
			t_min = t;
			hit_geom_index = i;
			intersect_point = tmp_intersect;
			normal = tmp_normal;
		}
	}
#ifdef USE_OCTREE
	// TODO: use octree for meshes
	int stack[200]; /// need to adjust according to MAX_DEPTH defined in octree.h
	int *ptr = stack;
	*ptr = -1;
	*++ptr = 0;
	
	int tmp_idx;
	bool tmp_outside;
	bool isLeaf;

	do {
		OctreeNode &node = octree_nodes[*ptr--]; // pop
		t = octreeNodeIntersectionTest(node, pathSegment.ray, 
			tmp_intersect, tmp_normal, tmp_outside, tmp_idx, geoms, geom_indices, isLeaf);
		if (t > 0.f && t < t_min && isLeaf) {
			t_min = t;
			hit_geom_index = tmp_idx;
			intersect_point = tmp_intersect;
			normal = tmp_normal;
			outside = tmp_outside;
		}
		else if (t > 0.f && !isLeaf) {
			for (int c : node.childrenIndices) {
				*++ptr = c;
			}
		}
	} while (*ptr >= 0);

	/*
	int idx;
	t = octreeIntersectionTest(octree_nodes[0], pathSegment.ray, tmp_intersect, tmp_normal, outside, idx, 
		geoms, geom_indices, octree_nodes);
	if (t > 0.0f && t_min > t) {
		t_min = t;
		hit_geom_index = idx;
		intersect_point = tmp_intersect;
		normal = tmp_normal;
	}
	*/
#endif
	
	if (hit_geom_index == -1)
	{
		intersections[path_index].t = -1.0f;
	}
	else
	{
		//The ray hits something
		intersections[path_index].t = t_min;
		intersections[path_index].materialId = geoms[hit_geom_index].materialid;
		intersections[path_index].surfaceNormal = normal;
		intersections[path_index].outside = outside;
	}
#if CACHE
	if (depth == 0) {
		cached_intersections[index] = intersections[index];
	}
#endif
}

// LOOK: "fake" shader demonstrating what you might do with the info in
// a ShadeableIntersection, as well as how to use thrust's random number
// generator. Observe that since the thrust random number generator basically
// adds "noise" to the iteration, the image should start off noisy and get
// cleaner as more iterations are computed.
//
// Note that this shader does NOT do a BSDF evaluation!
// Your shaders should handle that - this can allow techniques such as
// bump mapping.
__global__ void shadeFakeMaterial (
  int iter
  , int num_paths
	, ShadeableIntersection * shadeableIntersections
	, PathSegment *pathSegments
	, int *pathIndexes
	, Material * materials
	)
{
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < num_paths)
  {
	  //int idx = pathIndexes[index];
	  int idx = index;
    ShadeableIntersection intersection = shadeableIntersections[idx];
    if (intersection.t > 0.0f) { // if the intersection exists...
      // Set up the RNG
      // LOOK: this is how you use thrust's RNG! Please look at
      // makeSeededRandomEngine as well.
      thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
      thrust::uniform_real_distribution<float> u01(0, 1);

      Material material = materials[intersection.materialId];
      glm::vec3 materialColor = material.color;

      // If the material indicates that the object was a light, "light" the ray
      if (material.emittance > 0.0f) {
        pathSegments[idx].color *= (materialColor * material.emittance);
		pathSegments[idx].remainingBounces = -1;
      }
      // Otherwise, do some pseudo-lighting computation. This is actually more
      // like what you would expect from shading in a rasterizer like OpenGL.
      // TODO: replace this! you should be able to start with basically a one-liner
	  
	  else {
		  /*
		float lightTerm = glm::dot(intersection.surfaceNormal, glm::vec3(0.0f, 1.0f, 0.0f));
		pathSegments[idx].color *= (materialColor * lightTerm) * 0.3f + ((1.0f - intersection.t * 0.02f) * materialColor) * 0.7f;
		pathSegments[idx].color *= u01(rng); // apply some noise because why not
		*/
		  if (pathSegments[idx].remainingBounces <= 0) {
			  pathSegments[idx].color = glm::vec3(0.0f);
		  }
		  else {
			  scatterRay(pathSegments[idx], intersection, material, rng);
		  }
		  pathSegments[idx].remainingBounces -= 1;
      }
    // If there was no intersection, color the ray black.
    // Lots of renderers use 4 channel color, RGBA, where A = alpha, often
    // used for opacity, in which case they can indicate "no opacity".
    // This can be useful for post-processing and image compositing.
    } else {
      pathSegments[idx].color = glm::vec3(0.0f);
	  pathSegments[idx].remainingBounces = -1;
    }
	if (pathSegments[idx].remainingBounces < 0) {
		pathIndexes[index] = -1; // path ends
	}
  }
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3 * image, PathSegment * iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}
}

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4 *pbo, int frame, int iter) {
    const int traceDepth = hst_scene->state.traceDepth;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;
	const int num_nodes = hst_scene->octree.size();

	// 2D block for generating ray from camera
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
            (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
            (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

    ///////////////////////////////////////////////////////////////////////////

    // Recap:
    // * Initialize array of path rays (using rays that come out of the camera)
    //   * You can pass the Camera object to that kernel.
    //   * Each path ray must carry at minimum a (ray, color) pair,
    //   * where color starts as the multiplicative identity, white = (1, 1, 1).
    //   * This has already been done for you.
    // * For each depth:
    //   * Compute an intersection in the scene for each path ray.
    //     A very naive version of this has been implemented for you, but feel
    //     free to add more primitives and/or a better algorithm.
    //     Currently, intersection distance is recorded as a parametric distance,
    //     t, or a "distance along the ray." t = -1.0 indicates no intersection.
    //     * Color is attenuated (multiplied) by reflections off of any object
    //   * TODO: Stream compact away all of the terminated paths.
    //     You may use either your implementation or `thrust::remove_if` or its
    //     cousins.
    //     * Note that you can't really use a 2D kernel launch any more - switch
    //       to 1D.
    //   * TODO: Shade the rays that intersected something or didn't bottom out.
    //     That is, color the ray by performing a color computation according
    //     to the shader, then generate a new ray to continue the ray path.
    //     We recommend just updating the ray's PathSegment in place.
    //     Note that this step may come before or after stream compaction,
    //     since some shaders you write may also cause a path to terminate.
    // * Finally, add this iteration's results to the image. This has been done
    //   for you.

    // TODO: perform one iteration of path tracing

	generateRayFromCamera <<<blocksPerGrid2d, blockSize2d >>>(cam, iter, traceDepth, dev_paths);
	checkCUDAError("generate camera ray");
	
	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;
	int num_paths_const = num_paths;

	dim3 numblocksInit = (num_paths + blockSize1d - 1) / blockSize1d;
	//fillPathIndexes <<<numblocksInit, blockSize1d>>> (num_paths, dev_path_idxes);
	
	thrust::device_ptr<int> dev_thrust_pathIdxes(dev_path_idxes);
	thrust::device_ptr<int> dev_thrust_pathMats(dev_path_mats);

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	bool iterationComplete = false;
	while (!iterationComplete) {

		// clean shading chunks
		cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

		// tracing
		dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
		computeIntersections <<<numblocksPathSegmentTracing, blockSize1d>>> (
			depth
			, num_paths
			, dev_paths
			, dev_geoms
			, hst_scene->geoms.size()
			, dev_intersections
			, dev_intersections_cache
			, state_updated
			, num_nodes
			, dev_octree
			, dev_geom_idxes
			);
		checkCUDAError("trace one bounce");
		cudaDeviceSynchronize();
		depth++;
		state_updated = false;


		// TODO:
		// --- Shading Stage ---
		// Shade path segments based on intersections and generate new rays by
		// evaluating the BSDF.
		// Start off with just a big kernel that handles all the different
		// materials you have in the scenefile.
		// TODO: compare between directly shading the path segments and shading
		// path segments that have been reshuffled to be contiguous in memory.

		// TODO (ADD): sort rays by material
#if SORTBYMAT
		//thrust::sort_by_key(dev_thrust_pathMats, dev_thrust_pathMats + num_paths, dev_thrust_pathIdxes);
		thrust::sort_by_key(thrust::device, dev_intersections, dev_intersections + num_paths, dev_paths, sort_by_mat());
#endif
		shadeFakeMaterial<<<numblocksPathSegmentTracing, blockSize1d>>> (
		iter,
		num_paths,
		dev_intersections,
		dev_paths,
		dev_path_idxes,
		dev_materials
		);
		// TODO (ADD): stream compaction
		/*
		int *new_end = thrust::remove_if(thrust::device, dev_path_idxes, dev_path_idxes + num_paths, path_is_end());
		num_paths = new_end - dev_path_idxes;
		*/
		dev_path_end = thrust::stable_partition(thrust::device, dev_paths, dev_path_end, bounce_end());
		num_paths = dev_path_end - dev_paths;

		iterationComplete = (num_paths == 0);
		//iterationComplete = (thrust::count_if(thrust::device, dev_paths, dev_path_end, path_is_end()) == num_paths); // TODO: should be based off stream compaction results.
		//iterationComplete = (depth > 5000);
	}

	// Assemble this iteration and apply it to the image
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather<<<numBlocksPixels, blockSize1d>>>(num_paths_const, dev_image, dev_paths);

    ///////////////////////////////////////////////////////////////////////////

    // Send results to OpenGL buffer for rendering
    sendImageToPBO<<<blocksPerGrid2d, blockSize2d>>>(pbo, cam.resolution, iter, dev_image);

    // Retrieve image from GPU
    cudaMemcpy(hst_scene->state.image.data(), dev_image,
            pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

    checkCUDAError("pathtrace");
}
