import 'voter.dart';

class Household {
  final String houseNumber;
  final String normalizedHouseNumber;
  final int voterCount;
  final List<Voter> voters;

  const Household({
    required this.houseNumber,
    required this.normalizedHouseNumber,
    required this.voterCount,
    required this.voters,
  });
}
