twice : Int -> Int
twice x => x * 2

keep_alive : Int × Int × Int × Int × Int -> Int
keep_alive a b c d e => {
    let before = a + b + c + d + e
    let middle = twice(a + e)
    before + middle + a + b + c + d + e
}

keep_alive(1, 2, 3, 4, 5)
