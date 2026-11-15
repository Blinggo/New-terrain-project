class_name FixedPoint
extends RefCounted
## src/core/fixed_point.gd
##
## M01 / Task 1 - Quantisation helpers for DECISIONS.
##
## Why this exists: a biome boundary computed as `temperature > 0.33` can flip between ARM
## and x86 (or between compiler optimisation levels) when the float lands within one ULP of
## the threshold. Every *decision* in worldgen (which biome, which feature, which rock) must
## therefore compare QUANTISED INTEGERS at a declared resolution, so the comparison is exact
## integer arithmetic on every platform. Floats stay for continuous maths (noise, blending);
## they never gate a choice.
##
## LAYER: core, pure functions, no state.

## round(value * steps) as an int. `steps` is the resolution, e.g. 1024 for ~0.001.
static func quantize(value: float, steps: int) -> int:
	return int(roundf(value * float(steps)))


## Sign of (quantized(a) - quantized(b)): -1, 0 or +1. Decisions compare THIS, never a-b.
static func qcompare(a: float, b: float, steps: int) -> int:
	var qa := quantize(a, steps)
	var qb := quantize(b, steps)
	if qa < qb:
		return -1
	if qa > qb:
		return 1
	return 0


## a > b at the given resolution (ties are false).
static func qgreater(a: float, b: float, steps: int) -> bool:
	return qcompare(a, b, steps) > 0


## a >= b at the given resolution.
static func qat_least(a: float, b: float, steps: int) -> bool:
	return qcompare(a, b, steps) >= 0


## Snap a float to the resolution grid; the value a quantised decision actually represents.
static func qsnap(value: float, steps: int) -> float:
	return float(quantize(value, steps)) / float(steps)


## Stable dictionary key for a quantised value (banding, caching decision outcomes).
static func qkey(value: float, steps: int) -> int:
	return quantize(value, steps)
