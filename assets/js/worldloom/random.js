const UINT32_MAX = 0xffffffff
const ZERO_SEED_STATE = 0x6d2b79f5

export function xorshift32(seed) {
  let state = (Number(seed) >>> 0) || ZERO_SEED_STATE

  return {
    nextUint32() {
      state ^= state << 13
      state ^= state >>> 17
      state ^= state << 5
      state >>>= 0
      return state
    },

    nextFloat() {
      return this.nextUint32() / UINT32_MAX
    },
  }
}
