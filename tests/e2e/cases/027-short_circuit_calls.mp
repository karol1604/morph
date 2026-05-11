never : Int -> Bool
never n => never(n + 1)

let and_result = if false and never(0) then 99 else 7
let or_result = if true or never(1) then 11 else 99

and_result + or_result
