add : Int × Int -> Int
add a b => a + b

let b = 10
let a = {
    let a = b + 1 + add(b, 1)
    a + 1
}
let z = add(a, b) + 1
if z + 1 > 100 then 67 else 12
