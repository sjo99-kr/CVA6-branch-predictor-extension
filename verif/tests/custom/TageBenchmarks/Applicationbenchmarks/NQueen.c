#include <stdio.h>
#define N 10

volatile int sink;

int board[N];
int solutions = 0;

int is_safe(int row, int col) {

    for (int i = 0; i < row; i++) {

        int prev_col = board[i];

        if (prev_col == col)
            return 0;

        if (prev_col - i == col - row)
            return 0;

        if (prev_col + i == col + row)
            return 0;
    }

    return 1;
}

void solve(int row) {

    if (row == N) {
        solutions++;
        return;
    }

    for (int col = 0; col < N; col++) {

        if (is_safe(row, col)) {

            board[row] = col;

            solve(row + 1);
        }
    }
}

int main(int argc, char* arg[]) {

    solve(0);

    sink = solutions;

    return 0;
}