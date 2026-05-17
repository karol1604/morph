isEven : Int -> Bool
isEven n => {
    if n == 0 then
        true
    else if n == 1 then
        false
    else
        isEven(n - 2)
}


collatz : Int -> Int
collatz n => {
    if isEven(n) then
        n / 2
    else
        3 * n + 1
}

collatz_seq : Int -> Unit
collatz_seq n => {
    let x = n
    if x == 1 then
        printInt(x)
    else {
        printInt(x)
        collatz_seq(collatz(x))
    }
}

collatz_seq(6171)
if 1==1 then {
    let a = 1
    printInt(a)
}
