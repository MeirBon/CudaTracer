#pragma once

#include <glm/glm.hpp>
#include <immintrin.h>

#include <Tracer/BVH/BVHNode.cuh>
#include <Tracer/BVH/BVHTree.h>
#include <Tracer/Core/Triangle.cuh>
#include <Tracer/Core/SceneData.cuh>

struct SceneData;

struct MBVHTraversal {
	int leftFirst;
	int count;
};

struct MBVHHit {
	union {
		vec4 tmin4;
		float tmin[4];
		int tmini[4];
	};
	bvec4 result;
};

class MBVHTree;
class MBVHNode
{
public:
	MBVHNode() = default;

	~MBVHNode() = default;

	union {
		vec4 bminx4;
		float bminx[4]{};
	};
	union {
		vec4 bmaxx4;
		float bmaxx[4]{};
	};

	union {
		vec4 bminy4;
		float bminy[4]{};
	};
	union {
		vec4 bmaxy4;
		float bmaxy[4]{};
	};

	union {
		vec4 bminz4;
		float bminz[4]{};
	};
	union {
		vec4 bmaxz4;
		float bmaxz[4]{};
	};

	int child[4];
	int count[4];

	void SetBounds(unsigned int nodeIdx, const glm::vec3 &min, const glm::vec3 &max);

	void SetBounds(unsigned int nodeIdx, const AABB &bounds);

	__device__ __host__ inline MBVHHit intersect(const vec3& org, const vec3 &dirInverse, float *t) const
	{
		MBVHHit hit{};

		vec4 t1 = (bminx4 - org.x) * dirInverse.x;
		vec4 t2 = (bmaxx4 - org.x) * dirInverse.x;

		hit.tmin4 = glm::min(t1, t2);
		vec4 tmax = glm::max(t1, t2);

		t1 = (bminy4 - org.y) * dirInverse.y;
		t2 = (bmaxy4 - org.y) * dirInverse.y;

		hit.tmin4 = glm::max(hit.tmin4, glm::min(t1, t2));
		tmax = glm::min(tmax, glm::max(t1, t2));

		t1 = (bminz4 - org.z) * dirInverse.z;
		t2 = (bmaxz4 - org.z) * dirInverse.z;

		hit.tmin4 = glm::max(hit.tmin4, glm::min(t1, t2));
		tmax = glm::min(tmax, glm::max(t1, t2));

		hit.tmini[0] = ((hit.tmini[0] & 0xFFFFFFFC) | 0b00);
		hit.tmini[1] = ((hit.tmini[1] & 0xFFFFFFFC) | 0b01);
		hit.tmini[2] = ((hit.tmini[2] & 0xFFFFFFFC) | 0b10);
		hit.tmini[3] = ((hit.tmini[3] & 0xFFFFFFFC) | 0b11);

		hit.result = greaterThan(tmax, vec4(0.0f)) && lessThanEqual(hit.tmin4, tmax) && lessThan(hit.tmin4, vec4(*t));

		//hit.result[0] = (tmax.x > 0.0f) && (hit.tmin4.x <= tmax.x) && (hit.tmin4.x < *t);
		//hit.result[1] = (tmax.y > 0.0f) && (hit.tmin4.y <= tmax.y) && (hit.tmin4.y < *t);
		//hit.result[2] = (tmax.z > 0.0f) && (hit.tmin4.z <= tmax.z) && (hit.tmin4.z < *t);
		//hit.result[3] = (tmax.w > 0.0f) && (hit.tmin4.w <= tmax.w) && (hit.tmin4.w < *t);

		if (hit.tmin[0] > hit.tmin[1])
			swap_values(hit.tmin[0], hit.tmin[1]);
		if (hit.tmin[2] > hit.tmin[3])
			swap_values(hit.tmin[2], hit.tmin[3]);
		if (hit.tmin[0] > hit.tmin[2])
			swap_values(hit.tmin[0], hit.tmin[2]);
		if (hit.tmin[1] > hit.tmin[3])
			swap_values(hit.tmin[1], hit.tmin[3]);
		if (hit.tmin[2] > hit.tmin[3])
			swap_values(hit.tmin[2], hit.tmin[3]);

		return hit;
	}

	void MergeNodes(const BVHNode &node, const BVHNode *bvhPool, MBVHTree *bvhTree);

	void MergeNodesMT(const BVHNode &node, const BVHNode *bvhPool, MBVHTree *bvhTree,
		bool thread = true);

	void MergeNodes(const BVHNode &node, const std::vector<BVHNode> &bvhPool, MBVHTree *bvhTree);

	void MergeNodesMT(const BVHNode &node, const std::vector<BVHNode> &bvhPool, MBVHTree *bvhTree,
		bool thread = true);

	void GetBVHNodeInfo(const BVHNode &node, const BVHNode *pool, int &numChildren);

	void SortResults(const float *tmin, int &a, int &b, int &c, int &d) const;

	__device__ inline static void traverseMBVH(const vec3& org, const vec3& dir, float *t, int *hit_idx, const SceneData &scene)
	{
		MBVHTraversal todo[32];
		int stackptr = 0;

		todo[0].leftFirst = 0;
		todo[0].count = -1;

		const vec3 dirInverse = 1.0f / dir;

		while (stackptr >= 0) {
			const int leftFirst = todo[stackptr].leftFirst;
			const int count = todo[stackptr].count;
			stackptr--;

			if (count > -1) { // leaf node
				for (int i = 0; i < count; i++) {
					const int primIdx = scene.gpuPrimIndices[leftFirst + i];
					const uvec3 &indices = scene.indices[primIdx];

					if (triangle::intersect(org, dir, t, scene.vertices[indices.x], scene.vertices[indices.y], scene.vertices[indices.z], scene.triangleEpsilon))
						*hit_idx = primIdx;
				}
				continue;
			}

			const MBVHHit hit = scene.gpuMbvhNodes[leftFirst].intersect(org, dirInverse, t);
			for (int i = 3; i >= 0; i--) { // reversed order, we want to check best nodes first
				const int idx = (hit.tmini[i] & 0b11);
				if (hit.result[idx] == 1) {
					stackptr++;
					todo[stackptr].leftFirst = scene.gpuMbvhNodes[leftFirst].child[idx];
					todo[stackptr].count = scene.gpuMbvhNodes[leftFirst].count[idx];
					//todo[stackptr].tNear = hit.tmin[idx];
				}
			}
		}
	}

	__device__ inline static bool traverseMBVHShadow(const vec3& org, const vec3& dir, float maxDist, const SceneData &scene)
	{
		MBVHTraversal todo[32];
		int stackptr = 0;

		todo[0].leftFirst = 0;
		todo[0].count = -1;

		const vec3 dirInverse = 1.0f / dir;

		while (stackptr >= 0) {
			struct MBVHTraversal mTodo = todo[stackptr];
			stackptr--;

			if (mTodo.count > -1) { // leaf node
				for (int i = 0; i < mTodo.count; i++) {
					const int primIdx = scene.gpuPrimIndices[mTodo.leftFirst + i];
					const uvec3 &indices = scene.indices[primIdx];

					if (triangle::intersect(org, dir, &maxDist, scene.vertices[indices.x], scene.vertices[indices.y], scene.vertices[indices.z], scene.triangleEpsilon))
						return false;
				}
				continue;
			}

			MBVHHit hit = scene.gpuMbvhNodes[mTodo.leftFirst].intersect(org, dirInverse, &maxDist);
			if (hit.result[0] || hit.result[1] || hit.result[2] || hit.result[3]) {
				for (int i = 3; i >= 0; i--) { // reversed order, we want to check best nodes first
					const int idx = (hit.tmini[i] & 0b11);
					if (hit.result[idx] == 1) {
						stackptr++;
						todo[stackptr].leftFirst = scene.gpuMbvhNodes[mTodo.leftFirst].child[idx];
						todo[stackptr].count = scene.gpuMbvhNodes[mTodo.leftFirst].count[idx];
					}
				}
			}
		}

		// Nothing occluding
		return true;
	}

	__host__ inline static void traverseMBVH(const vec3& org, const vec3& dir, float *t, int *hit_idx, const MBVHNode* nodes, const unsigned int* primIndices, const TriangleList& tList)
	{
		MBVHTraversal todo[32];
		int stackptr = 0;

		todo[0].leftFirst = 0;
		todo[0].count = -1;

		const vec3 dirInverse = 1.0f / dir;

		while (stackptr >= 0) {
			struct MBVHTraversal mTodo = todo[stackptr];
			stackptr--;

			if (mTodo.count > -1) { // leaf node
				for (int i = 0; i < mTodo.count; i++) {
					const int primIdx = primIndices[mTodo.leftFirst + i];
					const uvec3 &indices = tList.m_Indices[primIdx];

					if (triangle::intersect(org, dir, t, tList.m_Vertices[indices.x], tList.m_Vertices[indices.y], tList.m_Vertices[indices.z], EPSILON_T))
						*hit_idx = primIdx;
				}
				continue;
			}

			MBVHHit hit = nodes[mTodo.leftFirst].intersect(org, dirInverse, t);
			if (any(hit.result)) {
				for (int i = 3; i >= 0; i--) { // reversed order, we want to check best nodes first
					const int idx = (hit.tmini[i] & 0b11);
					if (hit.result[idx] == 1) {
						stackptr++;
						todo[stackptr].leftFirst = nodes[mTodo.leftFirst].child[idx];
						todo[stackptr].count = nodes[mTodo.leftFirst].count[idx];
					}
				}
			}
		}
	}

	template <typename T>
	__device__ __host__ inline static void swap_values(T &a, T &b)
	{
		T c(a); a = b; b = c;
	}
};