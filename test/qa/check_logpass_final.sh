#!/bin/bash

for file in *.t.sol; do
    echo "=== $file ==="
    
    awk '
    /^[[:space:]]*function test/ {
        func_line = NR
        match($0, /test[^(]*/)
        func_name = substr($0, RSTART, RLENGTH)
        brace_count = 0
        in_func = 1
        has_logpass = 0
        next
    }
    
    in_func == 1 {
        if ($0 ~ /{/) brace_count++
        if ($0 ~ /}/) brace_count--
        
        if ($0 ~ /_logPass\(\)/) has_logpass = 1
        
        if (brace_count < 0) {
            in_func = 0
            if (has_logpass == 0) {
                print "  MISSING: " func_name " (line " func_line ")"
            }
        }
    }
    ' "$file"
done
