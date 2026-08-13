import 'failure.dart';

sealed class Outcome<T> {
  const Outcome();

  const factory Outcome.success(T value) = Success<T>;
  const factory Outcome.failure(Failure failure) = Failed<T>;
}

final class Success<T> extends Outcome<T> {
  const Success(this.value);

  final T value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Success<T> && value == other.value;

  @override
  int get hashCode => Object.hash(Success<T>, value);

  @override
  String toString() => 'Success<$T>($value)';
}

final class Failed<T> extends Outcome<T> {
  const Failed(this.failure);

  final Failure failure;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Failed<T> && failure == other.failure;

  @override
  int get hashCode => Object.hash(Failed<T>, failure);

  @override
  String toString() => 'Failed<$T>($failure)';
}
