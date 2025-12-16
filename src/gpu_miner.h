#ifndef POTRERO_GPU_MINER_H
#define POTRERO_GPU_MINER_H

#include "config/bitcoin-config.h"
#include <stdint.h>

namespace gpu {
#ifdef HAVE_CUDA
bool available();
bool mineChunk(const uint32_t headerWords[20], uint32_t startNonce, uint32_t tries,
               const uint32_t targetWords[8], uint32_t& foundNonce,
               uint32_t foundHash[8], uint32_t& tried);
#else
inline bool available() { return false; }
inline bool mineChunk(const uint32_t headerWords[20], uint32_t startNonce, uint32_t tries,
                      const uint32_t targetWords[8], uint32_t& foundNonce,
                      uint32_t foundHash[8], uint32_t& tried)
{
    tried = 0;
    return false;
}
#endif
}

#endif // POTRERO_GPU_MINER_H
