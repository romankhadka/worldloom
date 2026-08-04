import assert from "node:assert/strict"
import test from "node:test"

import {xorshift32} from "../js/worldloom/random.js"

test("xorshift32 reproduces the stored render contract sequence", () => {
  const random = xorshift32(1470300345)

  assert.equal(random.nextUint32(), 3241367299)
  assert.equal(random.nextUint32(), 3518971818)
  assert.equal(random.nextUint32(), 4278646127)
})

test("xorshift32 is repeatable and replaces a zero state", () => {
  const first = xorshift32(0)
  const second = xorshift32(0)

  assert.deepEqual(
    [first.nextFloat(), first.nextFloat(), first.nextFloat()],
    [second.nextFloat(), second.nextFloat(), second.nextFloat()],
  )
  assert.notEqual(xorshift32(0).nextUint32(), 0)
})
