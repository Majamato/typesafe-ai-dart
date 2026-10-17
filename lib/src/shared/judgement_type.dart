/// The kind of judgement a question asks and its answer carries. Each value's
/// `name` is the wire value of the `type` field.
///
/// [box] belongs to the experimental Box question; see
/// `package:typesafe_ai_dart/experimental.dart`.
enum JudgementType { noul, choice, score, box }
