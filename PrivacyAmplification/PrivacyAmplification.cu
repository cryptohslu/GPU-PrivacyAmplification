#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <cufftXt.h>
#include <cuda_fp16.h>
#include <iostream>
#include <iomanip>
#include <assert.h>
#include <algorithm>
#include <iterator>
#include <math.h>
#include <zmq.h>
#ifdef _WIN32
#include <windows.h>
#endif
#include <thread>
#include <atomic>
#include <bitset>
#include <future>
#include <iostream>
#include <fstream>
#include <sstream>
#include <chrono>
#include <math.h>
#include "yaml/Yaml.hpp"
#include "sha3/sha3.h"
#include "ThreadPool.h"
#include "PrivacyAmplification.h"

using namespace std;

#ifdef __CUDACC__
#define KERNEL_ARG2(grid, block) <<< grid, block >>>
#define KERNEL_ARG3(grid, block, sh_mem) <<< grid, block, sh_mem >>>
#define KERNEL_ARG4(grid, block, sh_mem, stream) <<< grid, block, sh_mem, stream >>>
#else
#define KERNEL_ARG2(grid, block)
#define KERNEL_ARG3(grid, block, sh_mem)
#define KERNEL_ARG4(grid, block, sh_mem, stream)
#endif

#ifdef __INTELLISENSE__
cudaError_t cudaMemcpyToSymbol(Complex symbol, const void* src, size_t count);
cudaError_t cudaMemcpyToSymbol(Real symbol, const void* src, size_t count);
int __float2int_rn(float in);
unsigned int atomicAdd(unsigned int* address, unsigned int val);
#define __syncthreads()
#endif

string address_seed_in;
string address_key_in;
string address_amp_out;

uint32_t vertical_len;
uint32_t horizontal_len;
uint32_t vertical_block;
uint32_t horizontal_block;
uint32_t desired_block;
uint32_t key_blocks;
uint32_t input_cache_block_size;
uint32_t output_cache_block_size;
uint32_t* recv_key;
uint32_t* toeplitz_seed;
uint32_t* key_start;
uint32_t* key_start_zero_pos;
uint32_t* key_rest;
uint32_t* key_rest_zero_pos;
uint8_t*  Output;

#if SHOW_DEBUG_OUTPUT == TRUE
Real* OutputFloat;
#endif
atomic<uint32_t> input_cache_read_pos;
atomic<uint32_t> input_cache_write_pos;
atomic<uint32_t> output_cache_read_pos;
atomic<uint32_t> output_cache_write_pos;
mutex printlock;


__device__ __constant__ Complex c0_dev;
__device__ __constant__ Real h0_dev;
__device__ __constant__ Real h1_reduced_dev;
__device__ __constant__ Real normalisation_float_dev;
__device__ __constant__ uint32_t sample_size_dev;
__device__ __constant__ uint32_t pre_mul_reduction_dev;

__device__ __constant__ uint32_t intTobinMask_dev[32] =
{
    0b10000000000000000000000000000000,
    0b01000000000000000000000000000000,
    0b00100000000000000000000000000000,
    0b00010000000000000000000000000000,
    0b00001000000000000000000000000000,
    0b00000100000000000000000000000000,
    0b00000010000000000000000000000000,
    0b00000001000000000000000000000000,
    0b00000000100000000000000000000000,
    0b00000000010000000000000000000000,
    0b00000000001000000000000000000000,
    0b00000000000100000000000000000000,
    0b00000000000010000000000000000000,
    0b00000000000001000000000000000000,
    0b00000000000000100000000000000000,
    0b00000000000000010000000000000000,
    0b00000000000000001000000000000000,
    0b00000000000000000100000000000000,
    0b00000000000000000010000000000000,
    0b00000000000000000001000000000000,
    0b00000000000000000000100000000000,
    0b00000000000000000000010000000000,
    0b00000000000000000000001000000000,
    0b00000000000000000000000100000000,
    0b00000000000000000000000010000000,
    0b00000000000000000000000001000000,
    0b00000000000000000000000000100000,
    0b00000000000000000000000000010000,
    0b00000000000000000000000000001000,
    0b00000000000000000000000000000100,
    0b00000000000000000000000000000010,
    0b00000000000000000000000000000001
};


__device__ __constant__ uint32_t ToBinaryBitShiftArray_dev[32] =
{
    #if AMPOUT_REVERSE_ENDIAN == TRUE
    7, 6, 5, 4, 3, 2, 1, 0, 15, 14, 13, 12, 11, 10, 9, 8, 23, 22, 21, 20, 19, 18, 17, 16, 31, 30, 29, 28, 27, 26, 25, 24
    #else
    31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0
    #endif
};


void printStream(ostream& os) {
    ostringstream& ss = dynamic_cast<ostringstream&>(os);
    printlock.lock();
    cout << ss.str() << flush;
    printlock.unlock();
}


void printlnStream(ostream& os) {
    ostringstream& ss = dynamic_cast<ostringstream&>(os);
    printlock.lock();
    cout << ss.str() << endl;
    printlock.unlock();
}


string convertStreamToString(ostream& os) {
    ostringstream& ss = dynamic_cast<ostringstream&>(os);
    return ss.str();
}


__global__
void calculateCorrectionFloat(uint32_t* count_one_of_global_seed, uint32_t* count_one_of_global_key, float* correction_float_dev)
{
    uint64_t count_multiplied = *count_one_of_global_seed * *count_one_of_global_key;
    double count_multiplied_normalized = count_multiplied / (double)sample_size_dev;
    double two = 2.0;
    Real count_multiplied_normalized_modulo = (float)modf(count_multiplied_normalized, &two);
    *correction_float_dev = count_multiplied_normalized_modulo;
}


__global__
void setFirstElementToZero(Complex* do1, Complex* do2)
{
    if (threadIdx.x == 0) {
        do1[0] = c0_dev;
    }
    else
    {
        do2[0] = c0_dev;
    }
}


__global__
void ElementWiseProduct(Complex* do1, Complex* do2)
{
    uint32_t i = blockIdx.x * blockDim.x + threadIdx.x;
    float r = pre_mul_reduction_dev;
    Real do1x = do1[i].x/r;
    Real do1y = do1[i].y/r;
    Real do2x = do2[i].x/r;
    Real do2y = do2[i].y/r;
    do1[i].x = do1x * do2x - do1y * do2y;
    do1[i].y = do1x * do2y + do1y * do2x;
}


__global__
void binInt2float(uint32_t* binIn, Real* realOut, uint32_t* count_one_global)
{
    //Multicast
    Real h0_local = h0_dev;
    Real h1_reduced_local = h1_reduced_dev;
    __shared__ uint32_t binInShared[32];

    uint32_t block = blockIdx.x;
    uint32_t idx = threadIdx.x;
    uint32_t maskToUse;
    uint32_t inPos;
    uint32_t outPos;
    maskToUse = idx % 32;
    inPos = idx / 32;
    outPos = 1024 * block + idx;

    if (threadIdx.x < 32) {
        binInShared[idx] = binIn[32 * block + idx];
    }
    __syncthreads();

    if ((binInShared[inPos] & intTobinMask_dev[maskToUse]) == 0) {
        realOut[outPos] = h0_local;
    }
    else
    {
        atomicAdd(count_one_global, 1);
        realOut[outPos] = h1_reduced_local;
    }
}


__global__
void ToBinaryArray(Real* invOut, uint32_t* binOut, uint32_t* key_rest_local, Real* correction_float_dev)
{
    const Real normalisation_float_local = normalisation_float_dev;
    const uint32_t block = blockIdx.x;
    const uint32_t idx = threadIdx.x;
    const Real correction_float = *correction_float_dev;
    
    __shared__ uint32_t key_rest_xor[31];
    __shared__ uint32_t binOutRawBit[992];
    if (idx < 992) {
        binOutRawBit[idx] = ((__float2int_rn(invOut[block * 992 + idx] / normalisation_float_local + correction_float) & 1)
            << ToBinaryBitShiftArray_dev[idx % 32]);
    }
    else if (idx < 1023)
    {
        #if AMPOUT_REVERSE_ENDIAN == TRUE
        uint32_t key_rest_little = key_rest_local[block * 31 + idx - 992];
        key_rest_xor[idx - 992] =
            ((((key_rest_little) & 0xff000000) >> 24) |
                (((key_rest_little) & 0x00ff0000) >> 8) |
                (((key_rest_little) & 0x0000ff00) << 8) |
                (((key_rest_little) & 0x000000ff) << 24));
        #else
                key_rest_xor[idx - 992] = key_rest_local[block * 31 + idx - 992];
        #endif
    }
    __syncthreads();

    if (idx < 31) {
        const uint32_t pos = idx * 32;
        uint32_t binOutLocal =
            (binOutRawBit[pos] | binOutRawBit[pos + 1] | binOutRawBit[pos + 2] | binOutRawBit[pos + 3] |
            binOutRawBit[pos + 4] | binOutRawBit[pos + 5] | binOutRawBit[pos + 6] | binOutRawBit[pos + 7] |
            binOutRawBit[pos + 8] | binOutRawBit[pos + 9] | binOutRawBit[pos + 10] | binOutRawBit[pos + 11] |
            binOutRawBit[pos + 12] | binOutRawBit[pos + 13] | binOutRawBit[pos + 14] | binOutRawBit[pos + 15] |
            binOutRawBit[pos + 16] | binOutRawBit[pos + 17] | binOutRawBit[pos + 18] | binOutRawBit[pos + 19] |
            binOutRawBit[pos + 20] | binOutRawBit[pos + 21] | binOutRawBit[pos + 22] | binOutRawBit[pos + 23] |
            binOutRawBit[pos + 24] | binOutRawBit[pos + 25] | binOutRawBit[pos + 26] | binOutRawBit[pos + 27] |
            binOutRawBit[pos + 28] | binOutRawBit[pos + 29] | binOutRawBit[pos + 30] | binOutRawBit[pos + 31])
            #if XOR_WITH_KEY_REST == TRUE
            ^ key_rest_xor[idx]
            #endif
            ;
        binOut[block * 31 + idx] = binOutLocal;
    }
}


void printBin(const uint8_t * position, const uint8_t * end) {
    while (position < end) {
        printf("%s", bitset<8>(*position).to_string().c_str());
        ++position;
    }
    cout << endl;
}


void printBin(const uint32_t* position, const uint32_t* end) {
    while (position < end) {
        printf("%s", bitset<32>(*position).to_string().c_str());
        ++position;
    }
    cout << endl;
}


inline void key2StartRest() {
    uint32_t* key_start_block = key_start + input_cache_block_size * input_cache_write_pos;
    uint32_t* key_rest_block = key_rest + input_cache_block_size * input_cache_write_pos;
    uint32_t* key_start_zero_pos_block = key_start_zero_pos + input_cache_write_pos;
    uint32_t* key_rest_zero_pos_block = key_rest_zero_pos + input_cache_write_pos;

    memcpy(key_start_block, recv_key, horizontal_block * sizeof(uint32_t));
    *(key_start_block + horizontal_block) = *(recv_key + horizontal_block) & 0b10000000000000000000000000000000;

    uint32_t j = horizontal_block;
    for (uint32_t i = 0; i < vertical_block - 1; ++i)
    {
        key_rest_block[i] = ((recv_key[j] << 1) | (recv_key[j + 1] >> 31));
        ++j;
    }
    key_rest_block[vertical_block - 1] = ((recv_key[j] << 1));

    uint32_t new_key_start_zero_pos = horizontal_block + 1;
    if (new_key_start_zero_pos < *key_start_zero_pos_block)
    {
        uint32_t key_start_fill_length = *key_start_zero_pos_block - new_key_start_zero_pos;
        memset(key_start_block + new_key_start_zero_pos, 0b00000000, key_start_fill_length * sizeof(uint32_t));
        *key_start_zero_pos_block = new_key_start_zero_pos;
    }
    
    uint32_t new_key_rest_zero_pos = desired_block - horizontal_block;
    if (new_key_rest_zero_pos < *key_rest_zero_pos_block)
    {
        uint32_t key_rest_fill_length = *key_rest_zero_pos_block - new_key_rest_zero_pos;
        memset(key_rest_block + new_key_rest_zero_pos, 0b00000000, key_rest_fill_length * sizeof(uint32_t));
        *key_rest_zero_pos_block = new_key_rest_zero_pos;
    }
}


inline void readMatrixSeedFromFile() {
    //Cryptographically random Toeplitz seed generated by XOR a self-generated
    //VeraCrypt key file (PRF: SHA-512) with ANU_20Oct2017_100MB_7
    //from the ANU Quantum Random Numbers Server (https://qrng.anu.edu.au/)
    ifstream seedfile(toeplitz_seed_path, ios::binary);

    if (seedfile.fail())
    {
        cout << "Can't open file \"" << toeplitz_seed_path << "\" => terminating!" << endl;
        exit(103);
        abort();
    }

    seedfile.seekg(0, ios::end);
    size_t seedfile_length = seedfile.tellg();
    seedfile.seekg(0, ios::beg);

    if (seedfile_length < desired_block * sizeof(uint32_t))
    {
        cout << "File \"" << toeplitz_seed_path << "\" is with " << seedfile_length << " bytes too short!" << endl;
        cout << "it is required to be at least " << desired_block * sizeof(uint32_t) << " bytes => terminating!" << endl;
        exit(104);
        abort();
    }

    char* toeplitz_seed_char = reinterpret_cast<char*>(toeplitz_seed + input_cache_block_size * input_cache_write_pos);
    seedfile.read(toeplitz_seed_char, desired_block * sizeof(uint32_t));
    for (uint32_t i = 0; i < input_blocks_to_cache; ++i) {
        uint32_t* toeplitz_seed_block = toeplitz_seed + input_cache_block_size * i;
        memcpy(toeplitz_seed_block, toeplitz_seed, input_cache_block_size * sizeof(uint32_t));
    }
}


inline void readKeyFromFile() {
    //Cryptographically random Toeplitz seed generated by XOR a self-generated
    //VeraCrypt key file (PRF: SHA-512) with ANU_20Oct2017_100MB_49
    //from the ANU Quantum Random Numbers Server (https://qrng.anu.edu.au/)
    ifstream keyfile(keyfile_path, ios::binary);

    if (keyfile.fail())
    {
        cout << "Can't open file \"" << keyfile_path << "\" => terminating!" << endl;
        exit(105);
        abort();
    }

    keyfile.seekg(0, ios::end);
    size_t keyfile_length = keyfile.tellg();
    keyfile.seekg(0, ios::beg);

    if (keyfile_length < key_blocks * sizeof(uint32_t))
    {
        cout << "File \"" << keyfile_path << "\" is with " << keyfile_length << " bytes too short!" << endl;
        cout << "it is required to be at least " << key_blocks * sizeof(uint32_t) << " bytes => terminating!" << endl;
        exit(106);
        abort();
    }

    char* recv_key_char = reinterpret_cast<char*>(recv_key);
    keyfile.read(recv_key_char, key_blocks * sizeof(uint32_t));
    key2StartRest();
    for (uint32_t i = 0; i < input_blocks_to_cache; ++i) {
        uint32_t* key_start_block = key_start + input_cache_block_size * i;
        uint32_t* key_rest_block = key_rest + input_cache_block_size * i;
        uint32_t* key_start_zero_pos_block = key_start_zero_pos + i;
        uint32_t* key_rest_zero_pos_block = key_rest_zero_pos + i;
        memcpy(key_start_block, key_start, input_cache_block_size * sizeof(uint32_t));
        memcpy(key_rest_block, key_rest, input_cache_block_size * sizeof(uint32_t));
        *key_start_zero_pos_block = *key_start_zero_pos;
        *key_rest_zero_pos_block = *key_rest_zero_pos;
    }
}


void reciveData() {
    int32_t rc;
    void* socket_seed_in = nullptr;
    void* socket_key_in = nullptr;
    void* context_seed_in = nullptr;
    void* context_key_in = nullptr;
    int timeout_seed_in = 1000;
    int timeout_key_in = 1000;

    if (use_matrix_seed_server)
    {
        context_seed_in = zmq_ctx_new();
        socket_seed_in = zmq_socket(context_seed_in, ZMQ_REQ);
        zmq_setsockopt(socket_seed_in, ZMQ_RCVTIMEO, &timeout_seed_in, sizeof(int));
        zmq_connect(socket_seed_in, address_seed_in.c_str());
    }
    else
    {
        readMatrixSeedFromFile();
    }

    if (use_key_server)
    {
        context_key_in = zmq_ctx_new();
        socket_key_in = zmq_socket(context_key_in, ZMQ_REQ);
        zmq_setsockopt(socket_key_in, ZMQ_RCVTIMEO, &timeout_key_in, sizeof(int));
        zmq_connect(socket_key_in, address_key_in.c_str());
    }
    else
    {
        readKeyFromFile();
    }

    bool recive_toeplitz_matrix_seed = use_matrix_seed_server;
    while (true)
    {

        while (input_cache_write_pos % input_blocks_to_cache == input_cache_read_pos) {
            this_thread::yield();
        }

        uint32_t* toeplitz_seed_block = toeplitz_seed + input_cache_block_size * input_cache_write_pos;
        if (recive_toeplitz_matrix_seed) {
            retry_receiving_seed:
            zmq_send(socket_seed_in, "SYN", 3, 0);
            if (zmq_recv(socket_seed_in, toeplitz_seed_block, desired_block * sizeof(uint32_t), 0) != desired_block * sizeof(uint32_t)) {
                println("Error receiving data from Seedserver! Retrying...");
                zmq_close(context_seed_in);
                socket_seed_in = zmq_socket(context_seed_in, ZMQ_REQ);
                zmq_setsockopt(socket_seed_in, ZMQ_RCVTIMEO, &timeout_seed_in, sizeof(int));
                zmq_connect(socket_seed_in, address_seed_in.c_str());
                goto retry_receiving_seed;
            }
            println("Seed Block recived");

            if (!dynamic_toeplitz_matrix_seed)
            {
                recive_toeplitz_matrix_seed = false;
                zmq_disconnect(socket_seed_in, address_seed_in.c_str());
                zmq_close(socket_seed_in);
                zmq_ctx_destroy(socket_seed_in);
                for (uint32_t i = 0; i < input_blocks_to_cache; ++i) {
                    uint32_t* toeplitz_seed_block = toeplitz_seed + input_cache_block_size * i;
                    memcpy(toeplitz_seed_block, toeplitz_seed, input_cache_block_size * sizeof(uint32_t));
                }
            }
        }

        if (use_key_server)
        {
            retry_receiving_key:
            if (zmq_send(socket_key_in, "SYN", 3, 0) != 3) {
                println("Error sending SYN to Keyserver! Retrying...");
                goto retry_receiving_key;
            }
            if (zmq_recv(socket_key_in, &vertical_block, sizeof(uint32_t), 0) != sizeof(uint32_t)) {
                println("Error receiving vertical_blocks from Keyserver! Retrying...");
                zmq_close(context_key_in);
                socket_key_in = zmq_socket(context_key_in, ZMQ_REQ);
                zmq_setsockopt(socket_seed_in, ZMQ_RCVTIMEO, &timeout_key_in, sizeof(int));
                zmq_connect(socket_key_in, address_key_in.c_str());
                goto retry_receiving_key;
            }
            vertical_len = vertical_block * 32;
            horizontal_len = sample_size - vertical_len;
            horizontal_block = horizontal_len / 32;
            if (zmq_recv(socket_key_in, recv_key, key_blocks * sizeof(uint32_t), 0) != key_blocks * sizeof(uint32_t)) {
                println("Error receiving data from Keyserver! Retrying...");
                zmq_close(context_key_in);
                socket_key_in = zmq_socket(context_key_in, ZMQ_REQ);
                zmq_setsockopt(socket_seed_in, ZMQ_RCVTIMEO, &timeout_key_in, sizeof(int));
                zmq_connect(socket_key_in, address_key_in.c_str());
                goto retry_receiving_key;
            }
            println("Key Block recived");
            key2StartRest();
        }

        #if SHOW_INPUT_DEBUG_OUTPUT == TRUE
        uint32_t* key_start_block = key_start + input_cache_block_size * input_cache_write_pos;
        uint32_t* key_rest_block = key_rest + input_cache_block_size * input_cache_write_pos;
        printlock.lock();
        cout << "Toeplitz Seed: ";
        printBin(toeplitz_seed_block, toeplitz_seed_block + desired_block);
        cout << "Key: ";
        printBin(recv_key, recv_key + key_blocks);
        cout << "Key Start: ";
        printBin(key_start_block, key_start_block + desired_block + 1);
        cout << "Key Rest: ";
        printBin(key_rest_block, key_rest_block + vertical_block + 1);
        fflush(stdout);
        printlock.unlock();
        #endif

        input_cache_write_pos = (input_cache_write_pos + 1) % input_blocks_to_cache;
    }

    if (use_matrix_seed_server && recive_toeplitz_matrix_seed) {
        zmq_disconnect(socket_seed_in, address_seed_in.c_str());
        zmq_close(socket_seed_in);
        zmq_ctx_destroy(socket_seed_in);
    }

    if (use_key_server)
    {
        zmq_disconnect(socket_key_in, address_key_in.c_str());
        zmq_close(socket_key_in);
        zmq_ctx_destroy(socket_key_in);
    }
}


void verifyData(const unsigned char* dataToVerify) {
    sha3_ctx sha3;
    rhash_sha3_256_init(&sha3);
    rhash_sha3_update(&sha3, dataToVerify, vertical_len / 8);
    unsigned char* hash = (unsigned char*)malloc(32);
    rhash_sha3_final(&sha3, hash);
    if (memcmp(hash, ampout_sha3, 32) == 0) {
        println("VERIFIED!")
    }
    else
    {
        println("VERIFICATION FAILED!")
            exit(101);
    }
}


void sendData() {
    int32_t rc;
    char syn[3];
    void* amp_out_socket = nullptr;
    if (host_ampout_server)
    {
        void* amp_out_context = zmq_ctx_new();
        amp_out_socket = zmq_socket(amp_out_context, ZMQ_REP);
        while (zmq_bind(amp_out_socket, address_amp_out.c_str()) != 0) {
            println("Binding to \"" << address_amp_out << "\" failed! Retrying...");
        }
    }

    int32_t ampOutsToStore = store_first_ampouts_in_file;
    fstream ampout_file;
    if (ampOutsToStore != 0) {
        ampout_file = fstream("ampout.bin", ios::out | ios::binary);
    }

    ThreadPool* verifyDataPool = nullptr;
    if (verify_ampout)
    {
        verifyDataPool = new ThreadPool(verify_ampout_threads);
    }
    auto start = chrono::high_resolution_clock::now();
    auto stop = chrono::high_resolution_clock::now();

    while (true) {

        while ((output_cache_read_pos + 1) % output_blocks_to_cache == output_cache_write_pos) {
            this_thread::yield();
        }
        output_cache_read_pos = (output_cache_read_pos + 1) % output_blocks_to_cache;

        uint8_t* output_block = Output + output_cache_block_size * output_cache_read_pos;
        #if SHOW_DEBUG_OUTPUT == TRUE
        uint8_t * outputFloat_block = OutputFloat + output_cache_block_size * output_cache_read_pos;
        #endif

        if (verify_ampout)
        {
            verifyDataPool->enqueue(verifyData, output_block);
        }

        if (ampOutsToStore != 0) {
            if (ampOutsToStore > 0) {
                --ampOutsToStore;
            }
            ampout_file.write((char*)&output_block[0], vertical_len / 8);
            ampout_file.flush();
            if (ampOutsToStore == 0) {
                ampout_file.close();
            }
        }

        if (host_ampout_server)
        {
            retry_sending_amp_out:
            rc = zmq_recv(amp_out_socket, syn, 3, 0);
            if (rc != 3 || syn[0] != 'S' || syn[1] != 'Y' || syn[2] != 'N') {
                println("Error receiving SYN! Retrying...");
                goto retry_sending_amp_out;
            }
            if (zmq_send(amp_out_socket, output_block, vertical_len / 8, 0) != vertical_len / 8) {
                println("Error sending data to AMPOUT client! Retrying...");
                goto retry_sending_amp_out;
            }
            println("Block sent to AMPOUT Client");
        }

        #if SHOW_DEBUG_OUTPUT == TRUE
        printlock.lock();
        for (size_t i = 0; i < min_template(dist_freq, 64); ++i)
        {
            printf("%f\n", outputFloat_block[i]);
        }
        printlock.unlock();
        #endif

        stop = chrono::high_resolution_clock::now();
        auto duration = chrono::duration_cast<chrono::microseconds>(stop - start).count();
        start = chrono::high_resolution_clock::now();

        if (show_ampout)
        {
            printlock.lock();
            cout << "Blocktime: " << duration/1000.0 << " ms => " << (1000000.0/duration)*(sample_size/1000000.0) << " Mbit/s" << endl;
            for (size_t i = 0; i < min_template(vertical_block * sizeof(uint32_t), 4); ++i)
            {
                printf("0x%02X: %s\n", output_block[i], bitset<8>(output_block[i]).to_string().c_str());
            }
            fflush(stdout);
            printlock.unlock();
        }
    }
}


void readConfig() {
    Yaml::Node root;
    cout << "Reading config.yaml..." << endl;
    try
    {
        Yaml::Parse(root, "config.yaml");
    }
    catch (const Yaml::Exception e)
    {
        cout << "Exception " << e.Type() << ": " << e.what() << endl;
        cout << "Can't open file config.yaml => terminating!" << endl;
        exit(102);
    }

    //45555 =>seed_in_alice, 46666 => seed_in_bob
    address_seed_in = root["address_seed_in"].As<string>("tcp://127.0.0.1:45555");
    address_key_in = root["address_key_in"].As<string>("tcp://127.0.0.1:47777");  //key_in
    address_amp_out = root["address_amp_out"].As<string>("tcp://127.0.0.1:48888"); //amp_out

    sample_size = pow(2, root["factor_exp"].As<uint32_t>(27));
    reduction = pow(2, root["reduction_exp"].As<uint32_t>(11));
    pre_mul_reduction = pow(2, root["pre_mul_reduction_exp"].As<uint32_t>(5));
    cuda_device_id_to_use = root["cuda_device_id_to_use"].As<uint32_t>(1);
    input_blocks_to_cache = root["input_blocks_to_cache"].As<uint32_t>(16); //Has to be larger then 1
    output_blocks_to_cache = root["output_blocks_to_cache"].As<uint32_t>(16); //Has to be larger then 1

    dynamic_toeplitz_matrix_seed = root["dynamic_toeplitz_matrix_seed"].As<bool>(true);
    show_ampout = root["show_ampout"].As<bool>(true);
    use_matrix_seed_server = root["use_matrix_seed_server"].As<bool>(true);
    use_key_server = root["use_key_server"].As<bool>(true);
    host_ampout_server = root["host_ampout_server"].As<bool>(true);
    store_first_ampouts_in_file = root["store_first_ampouts_in_file"].As<int32_t>(true);

    toeplitz_seed_path = root["toeplitz_seed_path"].As<string>("toeplitz_seed.bin");
    keyfile_path = root["keyfile_path"].As<string>("keyfile.bin");

    verify_ampout = root["verify_ampout"].As<bool>(true);
    verify_ampout_threads = root["verify_ampout_threads"].As<uint32_t>(8);
    
    
    vertical_len = sample_size / 4 + sample_size / 8;
    horizontal_len = sample_size / 2 + sample_size / 8;
    vertical_block = vertical_len / 32;
    horizontal_block = horizontal_len / 32;
    desired_block = sample_size / 32;
    key_blocks = desired_block + 1;
    input_cache_block_size = desired_block;
    output_cache_block_size = (desired_block + 31) * sizeof(uint32_t);
    recv_key = (uint32_t*)malloc(key_blocks * sizeof(uint32_t));
    key_start_zero_pos = (uint32_t*)malloc(input_blocks_to_cache * sizeof(uint32_t));
    key_rest_zero_pos = (uint32_t*)malloc(input_blocks_to_cache * sizeof(uint32_t));
}


inline void setConsoleDesign() {
    #ifdef _WIN32
    HANDLE hConsole = GetStdHandle(STD_OUTPUT_HANDLE);
    CONSOLE_SCREEN_BUFFER_INFO csbi;
    DWORD dwConSize;
    COORD coordScreen = { 0, 0 };
    DWORD cCharsWritten;
    GetConsoleScreenBufferInfo(hConsole, &csbi);
    dwConSize = csbi.dwSize.X * csbi.dwSize.Y;
    FillConsoleOutputAttribute(hConsole,
        FOREGROUND_RED | FOREGROUND_BLUE | FOREGROUND_GREEN | FOREGROUND_INTENSITY | BACKGROUND_BLUE,
        dwConSize, coordScreen, &cCharsWritten);
    SetConsoleTextAttribute(hConsole,
        FOREGROUND_RED | FOREGROUND_BLUE | FOREGROUND_GREEN | FOREGROUND_INTENSITY | BACKGROUND_BLUE);
    #endif
}


int main(int argc, char* argv[])
{
    //About
    string about = streamToString("# PrivacyAmplification v" << VERSION << " by Nico Bosshard from " << __DATE__ << " #");
    string border(about.length(), '#');
    cout << border << endl;
    cout << "# PrivacyAmplification v1.0 by Nico Bosshard from " << __DATE__ << " #" << endl;
    cout << border << endl << endl;

    readConfig();

    cout << "PrivacyAmplification with " << sample_size << " bits" << endl << endl;
    cudaSetDevice(cuda_device_id_to_use);
    setConsoleDesign();

    uint32_t dist_freq = sample_size / 2 + 1;
    input_cache_read_pos = input_blocks_to_cache - 1;
    input_cache_write_pos = 0;
    output_cache_read_pos = input_blocks_to_cache - 1;
    output_cache_write_pos = 0;

    uint32_t* count_one_of_global_seed;
    uint32_t* count_one_of_global_key;
    float* correction_float_dev;
    Real* di1; //Device Input 1
    Real* di2; //Device Input 2
    Real* invOut;  //Result of the IFFT (uses the same memory as do2)
    Complex* do1;  //Device Output 1 and result of ElementWiseProduct
    Complex* do2;  //Device Output 2 and result of the IFFT
    cudaStream_t FFTStream, BinInt2floatKeyStream, BinInt2floatSeedStream, CalculateCorrectionFloatStream,
        cpu2gpuKeyStartStream, cpu2gpuKeyRestStream, cpu2gpuSeedStream, gpu2cpuStream,
        ElementWiseProductStream, ToBinaryArrayStream;
    cudaStreamCreate(&FFTStream);
    cudaStreamCreate(&BinInt2floatKeyStream);
    cudaStreamCreate(&BinInt2floatSeedStream);
    cudaStreamCreate(&CalculateCorrectionFloatStream);
    cudaStreamCreate(&cpu2gpuKeyStartStream);
    cudaStreamCreate(&cpu2gpuKeyRestStream);
    cudaStreamCreate(&cpu2gpuSeedStream);
    cudaStreamCreate(&gpu2cpuStream);
    cudaStreamCreate(&ElementWiseProductStream);
    cudaStreamCreate(&ToBinaryArrayStream);

    // Create cuda event to measure the performance
    cudaEvent_t start;
    cudaEvent_t stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    // Allocate host pinned memory on RAM
    cudaMallocHost((void**)&toeplitz_seed, input_cache_block_size * sizeof(uint32_t) * input_blocks_to_cache);
    cudaMallocHost((void**)&key_start, input_cache_block_size * sizeof(uint32_t) * input_blocks_to_cache);
    cudaMallocHost((void**)&key_rest, input_cache_block_size * sizeof(uint32_t) * input_blocks_to_cache + 31 * sizeof(uint32_t));
    cudaMallocHost((void**)&Output, output_cache_block_size * output_blocks_to_cache);
    #if SHOW_DEBUG_OUTPUT == TRUE
    cudaMallocHost((void**)&OutputFloat, sample_size * sizeof(float) * output_blocks_to_cache);
    #endif

    //Set key_start_zero_pos and key_rest_zero_pos to their default values
    fill(key_start_zero_pos, key_start_zero_pos + input_blocks_to_cache, desired_block);
    fill(key_rest_zero_pos, key_rest_zero_pos + input_blocks_to_cache, desired_block);

    // Allocate memory on GPU
    cudaMalloc(&count_one_of_global_seed, sizeof(uint32_t));
    cudaMalloc(&count_one_of_global_key, sizeof(uint32_t));
    cudaMalloc(&correction_float_dev, sizeof(float));
    cudaCalloc((void**)&di1, sample_size * sizeof(Real));
    cudaMalloc((void**)&di2, sample_size * sizeof(Real));
    cudaMalloc((void**)&do1, sample_size * sizeof(Complex));
    cudaMalloc((void**)&do2, max(sample_size * sizeof(Complex), (sample_size + 992) * sizeof(Real)));
    invOut = reinterpret_cast<Real*>(do2); //invOut and do2 share together the same memory region

    register const Complex complex0 = make_float2(0.0f, 0.0f);
    register const Real float0 = 0.0f;
    register const Real float1_reduced = 1.0f/reduction;
    const uint32_t total_reduction = reduction * pre_mul_reduction;
    const float normalisation_float = ((float)sample_size) / ((float)total_reduction) / ((float)total_reduction);
    
    /*Copy constant variables from RAM to GPUs constant memory*/
    cudaMemcpyToSymbol(c0_dev, &complex0, sizeof(Complex));
    cudaMemcpyToSymbol(h0_dev, &float0, sizeof(float));
    cudaMemcpyToSymbol(h1_reduced_dev, &float1_reduced, sizeof(float));
    cudaMemcpyToSymbol(normalisation_float_dev, &normalisation_float, sizeof(float));
    cudaMemcpyToSymbol(sample_size_dev, &sample_size, sizeof(uint32_t));
    cudaMemcpyToSymbol(pre_mul_reduction_dev, &pre_mul_reduction, sizeof(uint32_t));

    /*The reciveData function is parallelly executed on a separate thread which we start now*/
    thread threadReciveObj(reciveData);
    threadReciveObj.detach();
    
    /*The sendData function is parallelly executed on a separate thread which we start now*/
    thread threadSendObj(sendData);
    threadSendObj.detach();
    
    /*Plan of the forward real to complex fast fourier transformation*/
    cufftHandle plan_forward_R2C;
    cufftResult result_forward_FFT = cufftPlan1d(&plan_forward_R2C, sample_size, CUFFT_R2C, 1);
    if (result_forward_FFT != CUFFT_SUCCESS)
    {
        println("Failed to plan FFT 1! Error Code: " << result_forward_FFT);
        exit(0);
    }
    cufftSetStream(plan_forward_R2C, FFTStream);

    /*Plan of the inverse complex to real fast fourier transformation*/
    cufftHandle plan_inverse_C2R;
    cufftResult result_inverse_FFT = cufftPlan1d(&plan_inverse_C2R, sample_size, CUFFT_C2R, 1);
    if (result_inverse_FFT != CUFFT_SUCCESS)
    {
        println("Failed to plan IFFT 1! Error Code: " << result_inverse_FFT);
        exit(0);
    }
    cufftSetStream(plan_inverse_C2R, FFTStream);

    /*relevant_keyBlocks variables are used to detect dirty memory regions*/
    uint32_t relevant_keyBlocks = horizontal_block + 1;
    uint32_t relevant_keyBlocks_old = 0;
    bool recalculate_toeplitz_matrix_seed = true;

    //##########################
    // Mainloop of main thread #
    //##########################
    while (true) {

        /*Spinlock waiting for data provider*/
        while ((input_cache_read_pos + 1) % input_blocks_to_cache == input_cache_write_pos) {
            this_thread::yield();
        }
        input_cache_read_pos = (input_cache_read_pos + 1) % input_blocks_to_cache; //Switch read cache

        /*Detect dirty memory regions parts*/
        relevant_keyBlocks_old = relevant_keyBlocks;
        relevant_keyBlocks = horizontal_block + 1;
        if (relevant_keyBlocks_old > relevant_keyBlocks) {
            /*Fill dirty memory regions parts with zeros*/
            cudaMemset(di1 + relevant_keyBlocks, 0b00000000, (relevant_keyBlocks_old - relevant_keyBlocks) * sizeof(Real));
        }

        cudaMemset(count_one_of_global_key, 0x00, sizeof(uint32_t));
        binInt2float KERNEL_ARG4((int)((relevant_keyBlocks*32+1023) / 1024), min_template(relevant_keyBlocks * 32, 1024), 0,
            BinInt2floatKeyStream) (key_start + input_cache_block_size * input_cache_read_pos, di1, count_one_of_global_key);
        if (recalculate_toeplitz_matrix_seed) {
            cudaMemset(count_one_of_global_seed, 0x00, sizeof(uint32_t));
            binInt2float KERNEL_ARG4((int)(((int)(sample_size)+1023) / 1024), min_template(sample_size, 1024), 0,
                BinInt2floatSeedStream) (toeplitz_seed + input_cache_block_size * input_cache_read_pos, di2, count_one_of_global_seed);
            cudaStreamSynchronize(BinInt2floatSeedStream);
        }
        cudaStreamSynchronize(BinInt2floatKeyStream);
        calculateCorrectionFloat KERNEL_ARG4(1, 1, 0, CalculateCorrectionFloatStream)
            (count_one_of_global_key, count_one_of_global_seed, correction_float_dev);
        cufftExecR2C(plan_forward_R2C, di1, do1);
        if (recalculate_toeplitz_matrix_seed) {
            cufftExecR2C(plan_forward_R2C, di2, do2);
        }
        cudaStreamSynchronize(FFTStream);
        cudaStreamSynchronize(CalculateCorrectionFloatStream);
        setFirstElementToZero KERNEL_ARG4(1, 2, 0, ElementWiseProductStream) (do1, do2);
        cudaStreamSynchronize(ElementWiseProductStream);
        ElementWiseProduct KERNEL_ARG4((int)((dist_freq + 1023) / 1024), min((int)dist_freq, 1024), 0, ElementWiseProductStream) (do1, do2);
        cudaStreamSynchronize(ElementWiseProductStream);
        cufftExecC2R(plan_inverse_C2R, do1, invOut);
        cudaStreamSynchronize(FFTStream);

        /*Spinlock waiting for the data consumer*/
        while (output_cache_write_pos % output_blocks_to_cache == output_cache_read_pos) {
            this_thread::yield();
        }

        /*Calculates where in the host pinned output memory the Privacy Amplification result will be stored*/
        uint32_t* binOut = reinterpret_cast<uint32_t*>(Output + output_cache_block_size * output_cache_write_pos);
        ToBinaryArray KERNEL_ARG4((int)((int)(vertical_block) / 31) + 1, 1023, 0, ToBinaryArrayStream)
            (invOut, binOut, key_rest + input_cache_block_size * input_cache_read_pos, correction_float_dev);
        cudaStreamSynchronize(ToBinaryArrayStream);

        if (!dynamic_toeplitz_matrix_seed)
        {
            recalculate_toeplitz_matrix_seed = false;
        }

        #if SHOW_DEBUG_OUTPUT == TRUE
        cudaMemcpy(OutputFloat + output_cache_block_size * output_cache_write_pos, invOut, dist_freq * sizeof(float), cudaMemcpyDeviceToHost);
        cudaMemcpy(OutputFloat + output_cache_block_size * output_cache_write_pos, correction_float_dev, sizeof(float), cudaMemcpyDeviceToHost);
        #endif

        output_cache_write_pos = (output_cache_write_pos + 1) % output_blocks_to_cache;
    }


    // Delete CUFFT Plans
    cufftDestroy(plan_forward_R2C);
    cufftDestroy(plan_inverse_C2R);

    // Deallocate memoriey on GPU and RAM
    cudaFree(di1);
    cudaFree(di2);
    cudaFree(invOut);
    cudaFree(do1);
    cudaFree(do2);
    cudaFree(Output);

    // Delete cuda events
    cudaEventDestroy(start);
    cudaEventDestroy(stop);

    return 0;
}
