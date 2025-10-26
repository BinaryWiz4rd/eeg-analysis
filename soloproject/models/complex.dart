import 'dart:math';

/// Represents a complex number with real and imaginary components.
class Complex {
  final double re, im;

  const Complex(this.re, this.im);

  Complex operator +(Complex other) => Complex(re + other.re, im + other.im);
  Complex operator -(Complex other) => Complex(re - other.re, im - other.im);
  Complex operator *(Complex other) => Complex(re * other.re - im * other.im, re * other.im + im * other.re);
  double abs() => sqrt(re * re + im * im);
  Complex expi(double theta) => Complex(cos(theta), sin(theta));
}