#include <stdint.h>

volatile int sink;

int main() {
    unsigned int x = 1;
    int sum = 0;

    for (int i = 0; i < 20000; i++) {
        x = x * 1103515245 + 12345;  // LCG
        if (x & 1)
            sum++;
    }

    sink = sum;
    return 0;
}