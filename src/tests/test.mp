add : Int × Int -> Int
add x y => x + y

fib : Int -> Int
fib n => {
  if n <= 1 then n
  else add(fib (n - 1) , fib (n - 2))
}

fib(10)
