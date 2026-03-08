#include <stdio.h>

volatile int sink;

int main(int argc, char* arg[]) {
    int sum = 0;

    for (int i = 0; i < 100000; i++) {
        if (i % 2 == 0)
            sum++;
    }

    sink = sum;
    return 0;
}