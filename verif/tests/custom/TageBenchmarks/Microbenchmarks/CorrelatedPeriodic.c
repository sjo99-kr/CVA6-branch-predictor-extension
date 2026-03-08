#include <stdint.h>
#include <stdio.h>


int main(int argc, char* arg[]) {
    int sum = 0;

for (int i = 0; i < 10000; i++) {
    int a = (i % 3 == 0); 
    int b = (i % 5 == 0);
    
    if (a && b) sum++; 
    if (a || b) sum--; 
}
    return;
}