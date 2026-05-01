x: Int × Int -> Int
x(a, b) => a + b

let b = 10
let a = {
    let a = b + 1 + x(b, 1)
    a + 1
}
let z = x(a, b) + 1
if z + 1 > 100 then 67 else 12
