#define N 4096
#define ITER 5000

volatile int sink;

int binary_search(int arr[], int size, int target){

    int left = 0;
    int right = size - 1;

    while(left <= right){

        int mid = (left + right) >> 1;

        if(arr[mid] == target)
            return mid;

        if(arr[mid] < target)
            left = mid + 1;
        else
            right = mid - 1;
    }

    return -1;
}

int main(int argc, char* arg[]) {

    static int arr[N];

    for(int i=0;i<N;i++)
        arr[i] = i;

    int sum = 0;

    for(int i=0;i<ITER;i++){
        int target = (i * 37) % N;
        sum += binary_search(arr, N, target);
    }

    sink = sum;

    return 0;
}