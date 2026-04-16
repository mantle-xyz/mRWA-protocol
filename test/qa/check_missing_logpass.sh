#!/bin/bash

for file in *.t.sol; do
    echo "=== Checking $file ==="
    
    # Extract all test function line numbers
    grep -n "^[[:space:]]*function test" "$file" | while IFS=: read -r line_num rest; do
        func_name=$(echo "$rest" | grep -o 'test[^(]*')
        
        # Find the closing brace of this function
        start=$((line_num + 1))
        end=$(awk -v start=$start 'NR >= start && /^[[:space:]]*}[[:space:]]*$/ {print NR; exit}' "$file")
        
        # Check if _logPass() exists in this range
        logpass_count=$(sed -n "${line_num},${end}p" "$file" | grep -c "_logPass()")
        
        if [ $logpass_count -eq 0 ]; then
            echo "  MISSING _logPass(): $func_name (line $line_num-$end)"
        fi
    done
done
