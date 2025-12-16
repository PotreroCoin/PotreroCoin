#include "gpu_miner.h"

#ifdef HAVE_CUDA

#include <cuda_runtime.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace {

static const size_t kHeaderWords = 20;
static const size_t kTargetWords = 8;
static const size_t kScryptScratchpadSize = 131072 + 63;

__device__ __constant__ uint32_t kSha256K[64] = {
    0x428a2f98ul, 0x71374491ul, 0xb5c0fbcful, 0xe9b5dba5ul,
    0x3956c25bul, 0x59f111f1ul, 0x923f82a4ul, 0xab1c5ed5ul,
    0xd807aa98ul, 0x12835b01ul, 0x243185beul, 0x550c7dc3ul,
    0x72be5d74ul, 0x80deb1feul, 0x9bdc06a7ul, 0xc19bf174ul,
    0xe49b69c1ul, 0xefbe4786ul, 0x0fc19dc6ul, 0x240ca1ccul,
    0x2de92c6ful, 0x4a7484aaul, 0x5cb0a9dcul, 0x76f988daul,
    0x983e5152ul, 0xa831c66dul, 0xb00327c8ul, 0xbf597fc7ul,
    0xc6e00bf3ul, 0xd5a79147ul, 0x06ca6351ul, 0x14292967ul,
    0x27b70a85ul, 0x2e1b2138ul, 0x4d2c6dfcul, 0x53380d13ul,
    0x650a7354ul, 0x766a0abbul, 0x81c2c92eul, 0x92722c85ul,
    0xa2bfe8a1ul, 0xa81a664bul, 0xc24b8b70ul, 0xc76c51a3ul,
    0xd192e819ul, 0xd6990624ul, 0xf40e3585ul, 0x106aa070ul,
    0x19a4c116ul, 0x1e376c08ul, 0x2748774cul, 0x34b0bcb5ul,
    0x391c0cb3ul, 0x4ed8aa4aul, 0x5b9cca4ful, 0x682e6ff3ul,
    0x748f82eeul, 0x78a5636ful, 0x84c87814ul, 0x8cc70208ul,
    0x90befffaul, 0xa4506cebul, 0xbef9a3f7ul, 0xc67178f2ul
};

struct GpuResult {
    uint32_t found;
    uint32_t nonce;
    uint32_t hash[kTargetWords];
    uint32_t tried;
};

struct GpuContext {
    cudaStream_t stream;
    uint32_t* headerWords;
    uint32_t* targetWords;
    GpuResult* result;
    bool ready;
};

static GpuContext g_context = {0, nullptr, nullptr, nullptr, false};
static bool g_cuda_checked = false;
static bool g_cuda_available = false;

inline void cleanupContext(GpuContext& ctx)
{
    if (ctx.result) {
        cudaFree(ctx.result);
        ctx.result = nullptr;
    }
    if (ctx.targetWords) {
        cudaFree(ctx.targetWords);
        ctx.targetWords = nullptr;
    }
    if (ctx.headerWords) {
        cudaFree(ctx.headerWords);
        ctx.headerWords = nullptr;
    }
    if (ctx.stream) {
        cudaStreamDestroy(ctx.stream);
        ctx.stream = 0;
    }
    ctx.ready = false;
}

bool ensureContext()
{
    if (g_cuda_available)
        return true;
    if (g_cuda_checked && !g_cuda_available)
        return false;
    g_cuda_checked = true;

    int device_count = 0;
    if (cudaGetDeviceCount(&device_count) != cudaSuccess || device_count == 0) {
        g_cuda_available = false;
        return false;
    }
    if (cudaSetDevice(0) != cudaSuccess) {
        g_cuda_available = false;
        return false;
    }

    GpuContext& ctx = g_context;
    ctx.stream = 0;
    ctx.headerWords = nullptr;
    ctx.targetWords = nullptr;
    ctx.result = nullptr;

    if (cudaStreamCreate(&ctx.stream) != cudaSuccess) {
        cleanupContext(ctx);
        g_cuda_available = false;
        return false;
    }
    if (cudaMalloc(&ctx.headerWords, kHeaderWords * sizeof(uint32_t)) != cudaSuccess) {
        cleanupContext(ctx);
        g_cuda_available = false;
        return false;
    }
    if (cudaMalloc(&ctx.targetWords, kTargetWords * sizeof(uint32_t)) != cudaSuccess) {
        cleanupContext(ctx);
        g_cuda_available = false;
        return false;
    }
    if (cudaMalloc(&ctx.result, sizeof(GpuResult)) != cudaSuccess) {
        cleanupContext(ctx);
        g_cuda_available = false;
        return false;
    }

    ctx.ready = true;
    g_cuda_available = true;
    return true;
}

bool disableCuda()
{
    cleanupContext(g_context);
    g_cuda_available = false;
    return false;
}

__device__ inline uint32_t read_le32(const uint8_t* data)
{
    return ((uint32_t)data[0]) | ((uint32_t)data[1] << 8) | ((uint32_t)data[2] << 16) | ((uint32_t)data[3] << 24);
}

__device__ inline void write_le32(uint8_t* data, uint32_t value)
{
    data[0] = value & 0xff;
    data[1] = (value >> 8) & 0xff;
    data[2] = (value >> 16) & 0xff;
    data[3] = (value >> 24) & 0xff;
}

__device__ inline void write_be32(uint8_t* data, uint32_t value)
{
    data[0] = (value >> 24) & 0xff;
    data[1] = (value >> 16) & 0xff;
    data[2] = (value >> 8) & 0xff;
    data[3] = value & 0xff;
}

__device__ inline void write_be64(uint8_t* data, uint64_t value)
{
    for (int i = 0; i < 8; ++i) {
        data[i] = (value >> (56 - 8 * i)) & 0xff;
    }
}

__device__ inline uint32_t rotl(uint32_t value, int bits)
{
    return (value << bits) | (value >> (32 - bits));
}

__device__ inline uint32_t Ch(uint32_t x, uint32_t y, uint32_t z) { return z ^ (x & (y ^ z)); }
__device__ inline uint32_t Maj(uint32_t x, uint32_t y, uint32_t z) { return (x & y) | (z & (x | y)); }
__device__ inline uint32_t Sigma0(uint32_t x) { return rotl(x, 30) ^ rotl(x, 19) ^ rotl(x, 10); }
__device__ inline uint32_t Sigma1(uint32_t x) { return rotl(x, 26) ^ rotl(x, 21) ^ rotl(x, 7); }
__device__ inline uint32_t sigma0(uint32_t x) { return rotl(x, 25) ^ rotl(x, 14) ^ (x >> 3); }
__device__ inline uint32_t sigma1(uint32_t x) { return rotl(x, 15) ^ rotl(x, 13) ^ (x >> 10); }

__device__ void sha256_transform(uint32_t state[8], const uint8_t chunk[64])
{
    uint32_t a = state[0];
    uint32_t b = state[1];
    uint32_t c = state[2];
    uint32_t d = state[3];
    uint32_t e = state[4];
    uint32_t f = state[5];
    uint32_t g = state[6];
    uint32_t h = state[7];
    uint32_t w[64];

    for (int i = 0; i < 16; ++i)
        w[i] = read_le32(chunk + 4 * i);
    for (int i = 16; i < 64; ++i)
        w[i] = sigma1(w[i - 2]) + w[i - 7] + sigma0(w[i - 15]) + w[i - 16];

    for (int i = 0; i < 64; ++i) {
        uint32_t t1 = h + Sigma1(e) + Ch(e, f, g) + kSha256K[i] + w[i];
        uint32_t t2 = Sigma0(a) + Maj(a, b, c);
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }

    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
    state[5] += f;
    state[6] += g;
    state[7] += h;
}

struct Sha256Ctx {
    uint32_t state[8];
    uint64_t bitlen;
    uint32_t datalen;
    uint8_t data[64];
};

__device__ void sha256_init(Sha256Ctx* ctx)
{
    ctx->state[0] = 0x6a09e667ul;
    ctx->state[1] = 0xbb67ae85ul;
    ctx->state[2] = 0x3c6ef372ul;
    ctx->state[3] = 0xa54ff53aul;
    ctx->state[4] = 0x510e527ful;
    ctx->state[5] = 0x9b05688cul;
    ctx->state[6] = 0x1f83d9abul;
    ctx->state[7] = 0x5be0cd19ul;
    ctx->bitlen = 0;
    ctx->datalen = 0;
}

__device__ void sha256_process_block(Sha256Ctx* ctx)
{
    sha256_transform(ctx->state, ctx->data);
    ctx->bitlen += 512;
    ctx->datalen = 0;
}

__device__ void sha256_update(Sha256Ctx* ctx, const uint8_t* data, size_t len)
{
    for (size_t i = 0; i < len; ++i) {
        ctx->data[ctx->datalen++] = data[i];
        if (ctx->datalen == 64)
            sha256_process_block(ctx);
    }
}

__device__ void sha256_final(Sha256Ctx* ctx, uint8_t hash[32])
{
    uint32_t i = ctx->datalen;

    if (ctx->datalen < 56) {
        ctx->data[i++] = 0x80;
        while (i < 56)
            ctx->data[i++] = 0x00;
    } else {
        ctx->data[i++] = 0x80;
        while (i < 64)
            ctx->data[i++] = 0x00;
        sha256_process_block(ctx);
        i = 0;
        while (i < 56)
            ctx->data[i++] = 0x00;
    }

    ctx->bitlen += ctx->datalen * 8ull;
    write_be64(ctx->data + 56, ctx->bitlen);
    sha256_process_block(ctx);

    for (int j = 0; j < 8; ++j)
        write_be32(hash + 4 * j, ctx->state[j]);
}

__device__ void hmac_sha256(const uint8_t* key, size_t keylen,
                             const uint8_t* data, size_t datalen,
                             uint8_t digest[32])
{
    uint8_t key_block[64];
    uint8_t o_key_pad[64];
    uint8_t i_key_pad[64];

    for (size_t i = 0; i < 64; ++i) {
        uint8_t byte = (i < keylen) ? key[i] : 0;
        i_key_pad[i] = byte ^ 0x36;
        o_key_pad[i] = byte ^ 0x5c;
    }

    Sha256Ctx ctx;
    sha256_init(&ctx);
    sha256_update(&ctx, i_key_pad, 64);
    sha256_update(&ctx, data, datalen);
    uint8_t inner_hash[32];
    sha256_final(&ctx, inner_hash);

    sha256_init(&ctx);
    sha256_update(&ctx, o_key_pad, 64);
    sha256_update(&ctx, inner_hash, 32);
    sha256_final(&ctx, digest);
}

__device__ void PBKDF2_SHA256(const uint8_t* passwd, size_t passwdlen,
                              const uint8_t* salt, size_t saltlen,
                              uint64_t c, uint8_t* buf, size_t dkLen)
{
    uint8_t saltbuf[84];
    uint8_t U[32];
    uint8_t T[32];

    memcpy(saltbuf, salt, saltlen);

    for (size_t i = 0; i * 32 < dkLen; ++i) {
        uint32_t block = (uint32_t)(i + 1);
        write_be32(saltbuf + saltlen, block);

        hmac_sha256(passwd, passwdlen, saltbuf, saltlen + 4, U);
        memcpy(T, U, 32);

        for (uint64_t j = 2; j <= c; ++j) {
            hmac_sha256(passwd, passwdlen, U, 32, U);
            for (int k = 0; k < 32; ++k)
                T[k] ^= U[k];
        }

        size_t clen = dkLen - i * 32;
        if (clen > 32)
            clen = 32;
        memcpy(buf + i * 32, T, clen);
    }
}

__device__ inline void xor_salsa8(uint32_t B[16], const uint32_t Bx[16])
{
    uint32_t x00 = (B[0] ^= Bx[0]);
    uint32_t x01 = (B[1] ^= Bx[1]);
    uint32_t x02 = (B[2] ^= Bx[2]);
    uint32_t x03 = (B[3] ^= Bx[3]);
    uint32_t x04 = (B[4] ^= Bx[4]);
    uint32_t x05 = (B[5] ^= Bx[5]);
    uint32_t x06 = (B[6] ^= Bx[6]);
    uint32_t x07 = (B[7] ^= Bx[7]);
    uint32_t x08 = (B[8] ^= Bx[8]);
    uint32_t x09 = (B[9] ^= Bx[9]);
    uint32_t x10 = (B[10] ^= Bx[10]);
    uint32_t x11 = (B[11] ^= Bx[11]);
    uint32_t x12 = (B[12] ^= Bx[12]);
    uint32_t x13 = (B[13] ^= Bx[13]);
    uint32_t x14 = (B[14] ^= Bx[14]);
    uint32_t x15 = (B[15] ^= Bx[15]);

    x04 ^= rotl(x00 + x12, 7);
    x09 ^= rotl(x05 + x01, 7);
    x14 ^= rotl(x10 + x06, 7);
    x03 ^= rotl(x15 + x11, 7);
    x08 ^= rotl(x04 + x00, 9);
    x13 ^= rotl(x09 + x05, 9);
    x02 ^= rotl(x14 + x10, 9);
    x07 ^= rotl(x03 + x15, 9);
    x12 ^= rotl(x08 + x04, 13);
    x01 ^= rotl(x13 + x09, 13);
    x06 ^= rotl(x02 + x14, 13);
    x11 ^= rotl(x07 + x03, 13);
    x00 ^= rotl(x12 + x08, 18);
    x05 ^= rotl(x01 + x13, 18);
    x10 ^= rotl(x06 + x02, 18);
    x15 ^= rotl(x11 + x07, 18);

    B[0] = x00 + B[0];
    B[1] = x01 + B[1];
    B[2] = x02 + B[2];
    B[3] = x03 + B[3];
    B[4] = x04 + B[4];
    B[5] = x05 + B[5];
    B[6] = x06 + B[6];
    B[7] = x07 + B[7];
    B[8] = x08 + B[8];
    B[9] = x09 + B[9];
    B[10] = x10 + B[10];
    B[11] = x11 + B[11];
    B[12] = x12 + B[12];
    B[13] = x13 + B[13];
    B[14] = x14 + B[14];
    B[15] = x15 + B[15];
}

__device__ void scrypt_1024_1_1_256(const uint8_t* input, uint8_t* output, uint8_t* scratchpad)
{
    uint8_t B[128];
    uint32_t X[32];
    uint32_t* V = reinterpret_cast<uint32_t*>((uintptr_t(scratchpad) + 63) & ~uintptr_t(63));

    PBKDF2_SHA256(input, 80, input, 80, 1, B, 128);

    for (int k = 0; k < 32; ++k)
        X[k] = read_le32(&B[4 * k]);

    for (int i = 0; i < 1024; ++i) {
        for (int k = 0; k < 32; ++k)
            V[i * 32 + k] = X[k];
        xor_salsa8(&X[0], &X[16]);
        xor_salsa8(&X[16], &X[0]);
    }

    for (int i = 0; i < 1024; ++i) {
        uint32_t j = 32 * (X[16] & 1023);
        for (int k = 0; k < 32; ++k)
            X[k] ^= V[j + k];
        xor_salsa8(&X[0], &X[16]);
        xor_salsa8(&X[16], &X[0]);
    }

    for (int k = 0; k < 32; ++k)
        write_le32(&B[4 * k], X[k]);

    PBKDF2_SHA256(input, 80, B, 128, 1, output, 32);
}

__device__ inline bool hash_leq(const uint32_t hash[kTargetWords], const uint32_t target[kTargetWords])
{
    for (int i = kTargetWords - 1; i >= 0; --i) {
        if (hash[i] < target[i])
            return true;
        if (hash[i] > target[i])
            return false;
    }
    return true;
}

__global__ void gpu_scrypt_kernel(const uint32_t* headerWords,
                                  uint32_t startNonce,
                                  uint32_t tries,
                                  const uint32_t* targetWords,
                                  GpuResult* result)
{
    if (tries == 0)
        return;

    uint8_t headerBytes[80];
    for (int idx = 0; idx < 20; ++idx)
        write_le32(headerBytes + 4 * idx, headerWords[idx]);

    uint8_t scratchpad[kScryptScratchpadSize];
    uint32_t attempts = 0;
    for (uint32_t trial = 0; trial < tries; ++trial) {
        uint32_t currentNonce = startNonce + trial;
        write_le32(headerBytes + 76, currentNonce);
        uint8_t hash[32];
        scrypt_1024_1_1_256(headerBytes, hash, scratchpad);
        uint32_t hashWords[kTargetWords];
        for (int w = 0; w < kTargetWords; ++w)
            hashWords[w] = read_le32(hash + 4 * w);

        if (hash_leq(hashWords, targetWords)) {
            if (atomicCAS(&result->found, 0u, 1u) == 0u) {
                result->nonce = currentNonce;
                for (int w = 0; w < kTargetWords; ++w)
                    result->hash[w] = hashWords[w];
                result->tried = trial + 1;
            }
            return;
        }
        attempts = trial + 1;
    }
    result->tried = attempts;
}

} // namespace

namespace gpu {

bool available()
{
    return ensureContext();
}

bool mineChunk(const uint32_t headerWords[20], uint32_t startNonce, uint32_t tries,
               const uint32_t targetWords[8], uint32_t& foundNonce,
               uint32_t foundHash[8], uint32_t& tried)
{
    if (!ensureContext()) {
        tried = 0;
        return false;
    }
    if (tries == 0) {
        tried = 0;
        return false;
    }

    GpuContext& ctx = g_context;
    if (cudaMemcpyAsync(ctx.headerWords, headerWords, kHeaderWords * sizeof(uint32_t),
                        cudaMemcpyHostToDevice, ctx.stream) != cudaSuccess) {
        return disableCuda();
    }
    if (cudaMemcpyAsync(ctx.targetWords, targetWords, kTargetWords * sizeof(uint32_t),
                        cudaMemcpyHostToDevice, ctx.stream) != cudaSuccess) {
        return disableCuda();
    }

    GpuResult reset = {};
    if (cudaMemcpyAsync(ctx.result, &reset, sizeof(reset), cudaMemcpyHostToDevice, ctx.stream) != cudaSuccess) {
        return disableCuda();
    }

    gpu_scrypt_kernel<<<1, 1, 0, ctx.stream>>>(ctx.headerWords, startNonce, tries, ctx.targetWords, ctx.result);

    if (cudaStreamSynchronize(ctx.stream) != cudaSuccess) {
        return disableCuda();
    }

    GpuResult hostResult;
    if (cudaMemcpy(&hostResult, ctx.result, sizeof(hostResult), cudaMemcpyDeviceToHost) != cudaSuccess) {
        return disableCuda();
    }

    tried = hostResult.tried ? hostResult.tried : tries;
    if (hostResult.found) {
        foundNonce = hostResult.nonce;
        for (int i = 0; i < kTargetWords; ++i)
            foundHash[i] = hostResult.hash[i];
        return true;
    }

    return false;
}

} // namespace gpu

#endif // HAVE_CUDA
