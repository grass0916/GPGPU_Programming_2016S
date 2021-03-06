#include "counting.h"
#include <cstdio>
#include <cassert>
#include <thrust/scan.h>
#include <thrust/transform.h>
#include <thrust/functional.h>
#include <thrust/device_ptr.h>
#include <thrust/execution_policy.h>

#define isLeftNode(n)  (n % 2 == 0) ? true : false
#define isRightNode(n) (n % 2 == 1) ? true : false
#define getParentIndex(si, h, p) si[h + 1] + p / 2
#define getRightChildIndex(si, h, p) si[h - 1] + (p + 1) * 2

// Problem 1: Count the Position in Words.
__global__ void setFenwickTreeIndexEachLayer(int *startIndex, int tsize, int maxHeight) {
    for (int i = 0, size = tsize, totalSize = 0; i < maxHeight; i++, size /= 2)
        startIndex[i] = totalSize, totalSize += size;
}

__global__ void characterNormalization(int *tree, const char *input, int tsize) {
    // Index of thread.
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    // Assign the value of character.
    tree[idx] = (idx < tsize && input[idx] != '\n') ? 1 : 0;
}

__global__ void buildFenwickTree(int * tree, int * startIndex, int tsize, int h) {
    // Index of thread.
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    // idp is 'previous layer' in fenwick tree.
    int idp = startIndex[h - 1] + idx;
    if (idp + 1 < startIndex[h] && isLeftNode((idp - startIndex[h - 1]))) {
        // idc is 'current layer' in fenwick tree.
        int idc = startIndex[h] + idx / 2;
        tree[idc] = (tree[idp] & tree[idp + 1]) ? tree[idp] + tree[idp + 1] : 0;
    }
}

__global__ void traverseFenwickTree(int *pos, int *tree, int maxHeight, int *startIndex, int tsize) {
    // Index of thread.
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    // Out of the string length, skip this thread.
    if (idx >= tsize) return;
    // Calculate the position.
    if (! tree[idx]) {
        pos[idx] = 0;
        return;
    }
    // Current length of substring. ; Current height of tree. ; Current position in this layer.
    int length = 0, height = 0, position = idx, currentIndex = idx;
    // Bottom up.
    while (true) {
        if (isLeftNode(position)) {
            if (position - 1 >= 0 && tree[currentIndex - 1]) {
                length += tree[currentIndex], position -= 1, currentIndex -= 1;
            } else {
                break;
            }
        } else {
            int parentIndex = getParentIndex(startIndex, height, position);
            if (tree[parentIndex]) {
                height += 1, position /= 2, currentIndex = parentIndex;
            } else {
                length += tree[currentIndex], position -= 1, currentIndex -= 1;
                break;
            }
        }
    }
    // Top down.
    while (true) {
        if (height == 0) {
            length += tree[currentIndex];
            break;
        } else if (tree[currentIndex]) {
            if (position - 1 >= 0) {
                length += tree[currentIndex], position -= 1, currentIndex -= 1;
            } else {
                length += tree[currentIndex];
                break;
            }
        } else {
            int rightIndex = getRightChildIndex(startIndex, height, position);
            if (tree[rightIndex]) {
                height -= 1, position = (position + 1) * 2 - 1, currentIndex = rightIndex - 1;
            } else {
                height -= 1, position = (position + 1) * 2, currentIndex = rightIndex;
            }
        }
    }
    pos[idx] = length;
}

void CountPosition(const char *text, int *pos, int text_size) {
    // GPU settings.
    int threads = 32, blocks;
    // Height counts are 9 layers (2^9 = 512) and one base layer. Start index in each layer.
    int *fenwickTree, *startIndex;
    int treeHeight = 10, treeTableSize = 0;
    // CUDA memory allocation.
    for (int i = 0, size = text_size; i < treeHeight; i++, size /= 2)
        treeTableSize += size;
    cudaMalloc(&fenwickTree, sizeof(int) * treeTableSize);
    cudaMemset(fenwickTree, 0, sizeof(int) * treeTableSize);
    cudaMalloc(&startIndex, sizeof(int) * treeHeight);
    // Create strat index table.
    setFenwickTreeIndexEachLayer <<< 1, 1 >>> (startIndex, text_size, treeHeight);
    // Convert character to 0 and 1.
    blocks = ceil((float) text_size / threads);
    characterNormalization <<< blocks, threads >>> (fenwickTree, text, text_size);
    // pi is 'previous index' ; ci is 'current index'.
    for (int h = 1; h < treeHeight; h++) {
        blocks = ceil((float) text_size / pow(2, (h - 1)) / threads);
        buildFenwickTree <<< blocks, threads >>> (fenwickTree, startIndex, text_size, h);
    }
    // Traverse the tree and calculate the position in substring.
    blocks = ceil((float) text_size / threads);
    traverseFenwickTree <<< blocks, threads >>> (pos, fenwickTree, treeHeight, startIndex, text_size);
    // Release memory.
    cudaFree(fenwickTree);
    return;
}

// Problem 2: Find the Heads.
struct equalToOne {
    __device__ bool operator() (const int num) { return num == 1; }
};

int ExtractHead(const int *pos, int *head, int text_size) {
    thrust::device_ptr<const int> posPtr(pos);
    thrust::device_ptr<int> headPtr(head);
    thrust::counting_iterator<int> firstIter(0), endIter(text_size);
    auto headEndPtr = thrust::copy_if(firstIter, endIter, posPtr, headPtr, equalToOne());
    int nhead = headEndPtr - headPtr;
    return nhead;
}

// Problem 3: Be Creative!
__global__ void transformToSwapPairs(char *input, int fsize) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    // Current char.
    char cur_c = input[idx];
    int idx_in_str = 0;
    // 
    if ((cur_c >= 'A' && cur_c <= 'Z') || (cur_c >= 'a' && cur_c <= 'z')) {
        // Get the index in the current string.
        for (int i = idx - 1; i >= 0; i--) {
            char c = input[i];
            if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) {
                idx_in_str++;
            } else {
                break;
            }
        }
        // Swap by string pairs.
        if (! (idx_in_str % 2) && idx < fsize) {
            char c = input[idx + 1];
            if (c >= 'A' && c <= 'Z') {
                if (cur_c >= 'a' && cur_c <= 'z')
                    input[idx] = c + 32, input[idx + 1] = cur_c - 32;
                else
                    input[idx] = c, input[idx + 1] = cur_c;
            } else if (c >= 'a' && c <= 'z') {
                if (cur_c >= 'a' && cur_c <= 'z')
                    input[idx] = c, input[idx + 1] = cur_c;
                else
                    input[idx] = c - 32, input[idx + 1] = cur_c + 32;
            }
        }
    }
}

void Part3(char *text, int *pos, int *head, int text_size, int n_head) {
    int threads = 32;
    int blocks = ceil((float) text_size / threads);;
    transformToSwapPairs <<< blocks, threads >>> (text, text_size);
    return;
}