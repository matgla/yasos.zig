#include <stdio.h>

int main() {
  int number = 0;
  printf("Hello, World!\n");
  printf("This is a simple C program.\n");
  printf("Please provide number: ");
  fflush(stdout);
  scanf("%d", &number);
  printf("You entered: %d\n", number);
  return 0;
}
