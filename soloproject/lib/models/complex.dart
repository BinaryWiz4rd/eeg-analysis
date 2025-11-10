import 'dart:math';

class Complex {
  final double real;
  final double imag;

  const Complex(this.real, this.imag);

  Complex operator +(Complex b) => Complex(real + b.real, imag + b.imag);
  Complex operator -(Complex b) => Complex(real - b.real, imag - b.imag);
  Complex operator *(Complex b) =>
      Complex(real * b.real - imag * b.imag, real * b.imag + imag * b.real);

  double magnitude() => sqrt(real * real + imag * imag);
}