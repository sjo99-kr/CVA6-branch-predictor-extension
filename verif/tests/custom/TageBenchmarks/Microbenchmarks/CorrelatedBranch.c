#include <stdio.h>

volatile int sink;

int main(int argc, char* arg[]) {
    int sum = 0;

    for (int i = 0; i < 100000; i++) {

        int a = (i % 3 == 0);

        if (a)
            sum++;

        if (a)
            sum--;

    }

    sink = sum;
    return 0;
}