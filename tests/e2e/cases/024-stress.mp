abs : Int -> Int
abs x => if x < 0 then -x else x

clamp : Int × Int × Int -> Int
clamp lo hi x => {
    if x < lo then lo
    else if x > hi then hi
    else x
}

pow2 : Int -> Int
pow2 n => if n <= 0 then 1 else 2 * pow2(n - 1)

let raw = -37
let a   = abs(raw)
let b   = clamp(1, 10, a)
let c   = pow2(b / 2)
let adj = if a > 30 and b == 10 then c + 10 else 0
adj
