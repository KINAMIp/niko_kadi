import '../models/game_state.dart';
import '../models/kadi_card.dart';
import '../models/kadi_player.dart';

class AceRequestPayload {
  final Suit suit;
  final Rank rank;

  const AceRequestPayload({required this.suit, required this.rank});

  String get label => '${rank.label}${suit == Suit.joker ? '' : suit.label[0]}';
}

class PlayIntent {
  final String playerId;
  final List<KadiCard> cards;
  final AceRequestPayload? aceRequest;

  const PlayIntent({
    required this.playerId,
    required this.cards,
    this.aceRequest,
  });
}

class RuleOutcome {
  final bool isValid;
  final String? error;
  final GameState? state;
  final List<String> timeline;
  final String? prompt;

  const RuleOutcome._({
    required this.isValid,
    this.error,
    this.state,
    this.timeline = const [],
    this.prompt,
  });

  factory RuleOutcome.invalid(String message) =>
      RuleOutcome._(isValid: false, error: message);

  factory RuleOutcome.success({
    required GameState state,
    List<String> timeline = const [],
    String? prompt,
  }) =>
      RuleOutcome._(
        isValid: true,
        state: state,
        timeline: timeline,
        prompt: prompt,
      );
}

class RuleEngine {
  const RuleEngine();

  RuleOutcome play(GameState state, PlayIntent intent) {
    if (state.gameStatus != 'playing') {
      return RuleOutcome.invalid('Game is not in a playable state.');
    }

    if (state.isWaitingForCancel) {
      return RuleOutcome.invalid('A cancel window is active. Resolve it first.');
    }

    final playerIndex = state.players.indexWhere((p) => p.uid == intent.playerId);
    if (playerIndex == -1) {
      return RuleOutcome.invalid('Player not part of the game.');
    }

    if (playerIndex != state.turnIndex) {
      return RuleOutcome.invalid("It's not your turn.");
    }

    if (intent.cards.isEmpty) {
      return RuleOutcome.invalid('You must play at least one card.');
    }

    final player = state.players[playerIndex];
    final handIds = player.hand.map((e) => e.id).toSet();
    for (final card in intent.cards) {
      if (!handIds.contains(card.id)) {
        return RuleOutcome.invalid('Attempted to play a card that is not in hand.');
      }
    }

    final ctx = _PlayContext(state: state, player: player, intent: intent);
    final validator = _PlayValidator(ctx);
    final validationError = validator.validate();
    if (validationError != null) {
      return RuleOutcome.invalid(validationError);
    }

    return RuleOutcome.success(
      state: validator.apply(),
      timeline: validator.timeline,
      prompt: validator.prompt,
    );
  }
}

class _PlayContext {
  final GameState state;
  final KadiPlayer player;
  final PlayIntent intent;

  _PlayContext({
    required this.state,
    required this.player,
    required this.intent,
  });
}

class _PlayValidator {
  final _PlayContext ctx;
  final List<String> timeline = [];
  String? prompt;

  _PlayValidator(this.ctx);

  GameState get state => ctx.state;
  KadiPlayer get player => ctx.player;
  List<KadiCard> get cards => ctx.intent.cards;

  String? validate() {
    if (state.pendingWin != null) {
      return 'Waiting for win confirmation.';
    }

    if (state.aceRequest != null) {
      final error = _validateAceRequestResponse();
      if (error != null) return error;
      return null;
    }

    if (state.penaltyState.isActive) {
      final error = _validatePenaltyPlay();
      if (error != null) return error;
      return null;
    }

    return _validateNormalPlay();
  }

  String? _validateAceRequestResponse() {
    if (cards.length != 1) {
      return 'Only one card may be played in response to an Ace request.';
    }
    final request = state.aceRequest!;
    if (request.targetPlayer != player.uid) {
      return 'Ace request is aimed at another player.';
    }
    final card = cards.first;
    if (card.isAce) {
      return null;
    }
    if (card.suit == request.suit && card.rank == request.rank) {
      return null;
    }
    return 'You must play the requested card or another Ace.';
  }

  String? _validatePenaltyPlay() {
    for (final card in cards) {
      if (!card.isPenaltyCard && !card.isAce) {
        return 'Only penalty cards or Aces can be played during a penalty chain.';
      }
    }
    if (cards.length == 1 && cards.first.isAce) {
      return null;
    }

    KadiCard previous = state.penaltyState.lastPenalty ?? state.topCard!;
    for (final card in cards) {
      if (!card.isPenaltyCard) {
        return 'All cards must keep the penalty chain going.';
      }
      if (!_penaltyMatches(previous, card)) {
        return 'Penalty cards must match by suit, rank, or color.';
      }
      previous = card;
    }
    return null;
  }

  bool _penaltyMatches(KadiCard top, KadiCard next) {
    if (top.isJoker && next.isJoker) {
      return top.color == next.color;
    }
    if (top.isJoker) {
      return next.color == top.color;
    }
    if (next.isJoker) {
      return next.color == top.color;
    }
    return top.rank == next.rank || top.suit == next.suit;
  }

  String? _validateNormalPlay() {
    final top = state.topCard;
    if (top == null) {
      return 'Deck has not been initialised yet.';
    }

    if (cards.first.isPenaltyCard) {
      return _validatePenaltyStarter(top);
    }

    if (cards.first.isAceOfSpades) {
      if (cards.length != 1) {
        return 'Ace of Spades must be played alone.';
      }
      if (ctx.intent.aceRequest == null) {
        return 'Ace of Spades requires a requested card.';
      }
      return null;
    }

    if (cards.first.isAce) {
      if (cards.length != 1) {
        return 'Aces must be played individually.';
      }
      return null;
    }

    if (cards.first.isQuestionCard) {
      return _validateQuestionCombo(top);
    }

    if (cards.first.isSkip) {
      return _validateJumpCombo(top);
    }

    if (cards.first.isReverse) {
      return _validateKickCombo(top);
    }

    return _validateOrdinaryCombo(top);
  }

  String? _validatePenaltyStarter(KadiCard top) {
    if (!cards.first.matches(top, requiredSuit: state.requiredSuit)) {
      return 'Penalty card must match the pile.';
    }
    KadiCard previous = cards.first;
    for (final card in cards.skip(1)) {
      if (!card.isPenaltyCard) {
        return 'Penalty combos may contain only 2s, 3s, or Jokers.';
      }
      if (!_penaltyMatches(previous, card)) {
        return 'Penalty cards must match by suit, rank, or color.';
      }
      previous = card;
    }
    return null;
  }

  String? _validateQuestionCombo(KadiCard top) {
    if (!cards.first.matches(top, requiredSuit: state.requiredSuit)) {
      return 'First question card must match the pile.';
    }
    final questions = cards.takeWhile((c) => c.rank == cards.first.rank).toList();
    final answers = cards.skip(questions.length).toList();
    if (answers.isEmpty) {
      return 'Question cards must be followed by an answer.';
    }
    final lastQuestion = questions.last;
    if (!answers.first.isOrdinary) {
      return 'Answers must be ordinary cards.';
    }
    if (answers.first.suit != lastQuestion.suit) {
      return 'First answer must follow the last question suit.';
    }
    final answerRank = answers.first.rank;
    for (final answer in answers) {
      if (!answer.isOrdinary) {
        return 'Answers must be ordinary cards.';
      }
      if (answer.rank != answerRank) {
        return 'All answers must share the same rank.';
      }
    }
    for (final q in questions.skip(1)) {
      if (q.rank != questions.first.rank) {
        return 'All question cards must have the same rank.';
      }
    }
    return null;
  }

  String? _validateJumpCombo(KadiCard top) {
    if (!cards.first.matches(top, requiredSuit: state.requiredSuit)) {
      return 'Jump must match the pile.';
    }
    for (final card in cards) {
      if (!card.isSkip) {
        return 'Jump combos may contain only Jacks.';
      }
    }
    return null;
  }

  String? _validateKickCombo(KadiCard top) {
    if (!cards.first.matches(top, requiredSuit: state.requiredSuit)) {
      return 'Kickback must match the pile.';
    }
    for (final card in cards) {
      if (!card.isReverse) {
        return 'Kickback combos may contain only Kings.';
      }
    }
    return null;
  }

  String? _validateOrdinaryCombo(KadiCard top) {
    if (!cards.first.matches(top, requiredSuit: state.requiredSuit)) {
      return 'First card must match by suit or rank.';
    }
    final rank = cards.first.rank;
    for (final card in cards.skip(1)) {
      if (card.rank != rank) {
        return 'Combos must share the same rank.';
      }
      if (!card.isOrdinary) {
        return 'Only ordinary cards may be part of the combo.';
      }
    }
    return null;
  }

  GameState apply() {
    final activeRequest = state.aceRequest;
    var nextState = state;
    final updatedPlayers = List<KadiPlayer>.from(state.players);
    final playerIndex = updatedPlayers.indexWhere((p) => p.uid == player.uid);
    final newHand = List<KadiCard>.from(player.hand);
    for (final card in cards) {
      newHand.removeWhere((c) => c.id == card.id);
    }
    updatedPlayers[playerIndex] = player.copyWith(hand: newHand);

    final discard = List<KadiCard>.from(state.discardPile)..addAll(cards);

    nextState = nextState.copyWith(
      players: updatedPlayers,
      discardPile: discard,
      requiredSuit: null,
      overrideTopCard: null,
      aceRequest: null,
      statusMessage: null,
    );

    if (activeRequest != null) {
      if (cards.first.isAce) {
        timeline.add('${player.name} canceled the request with an Ace.');
      } else {
        timeline.add(
            '${player.name} honored the request with ${cards.first.rank.label}${cards.first.suit.label[0]}.');
      }
    }

    if (state.penaltyState.isActive) {
      if (cards.first.isAce) {
        timeline.add('${player.name} canceled the penalty.');
        final previous = state.penaltyState.lastPenalty;
        final matchCard = previous ?? state.topCard;
        nextState = nextState.copyWith(
          penaltyState: const PenaltyState(),
          overrideTopCard: previous,
          statusMessage: matchCard == null
              ? null
              : 'Penalty cleared. Match ${matchCard.rank.label}${matchCard.suit.label[0]}.',
        );
        return _completeTurn(nextState);
      }
      final pending = state.penaltyState.pendingDraw +
          cards.fold<int>(0, (sum, c) => sum + c.penaltyValue);
      final stack = List<KadiCard>.from(state.penaltyState.stack)..addAll(cards);
      timeline.add(
          '${player.name} stacked a penalty. Pending draw is now $pending.');
      nextState = nextState.copyWith(
        penaltyState: state.penaltyState.copyWith(
          pendingDraw: pending,
          stack: stack,
        ),
        statusMessage:
            'Pending draw $pending. Next player must continue penalty or pick.',
      );
      return _completeTurn(nextState);
    }

    final first = cards.first;
    if (first.isPenaltyCard) {
      final pending = cards.fold<int>(0, (sum, c) => sum + c.penaltyValue);
      timeline.add(
          '${player.name} started a penalty chain worth $pending card(s).');
      nextState = nextState.copyWith(
        penaltyState: PenaltyState(
          pendingDraw: pending,
          stack: List<KadiCard>.from(cards),
        ),
        statusMessage:
            'Pending draw $pending. Next player must continue penalty or pick.',
      );
      return _completeTurn(nextState);
    }

    if (first.isAceOfSpades) {
      final payload = ctx.intent.aceRequest!;
      final targetIndex = nextState.advanceIndex(1);
      final target = nextState.players[targetIndex];
      timeline.add(
          '${player.name} requested ${payload.label} from ${target.name}.');
      nextState = nextState.copyWith(
        penaltyState: const PenaltyState(),
        aceRequest: AceRequest(
          suit: payload.suit,
          rank: payload.rank,
          requestedBy: player.uid,
          targetPlayer: target.uid,
        ),
        requiredSuit: null,
        statusMessage:
            '${target.name}, play ${payload.label} or draw 1 if unavailable.',
      );
      return _completeTurn(nextState);
    }

    if (first.isAce) {
      timeline.add('${player.name} changed suit to ${first.suit.label}.');
      nextState = nextState.copyWith(
        penaltyState: const PenaltyState(),
        requiredSuit: first.suit,
        statusMessage: 'Play continues in ${first.suit.label}.',
      );
      return _completeTurn(nextState);
    }

    if (first.isSkip) {
      final skipCount = cards.length;
      final expires = DateTime.now().add(const Duration(seconds: 10));
      final targetIndex = nextState.advanceIndex(1);
      timeline.add('${player.name} jumped $skipCount player(s).');
      nextState = nextState.copyWith(
        cancelWindow: CancelWindow(
          type: CancelType.jump,
          initiatedBy: player.uid,
          expiresAt: expires,
          effectCount: skipCount,
          targetTurnIndex: targetIndex,
        ),
        statusMessage:
            'Jump in effect. Any player may cancel with a Jack within 10s.',
      );
      return _completeTurn(nextState);
    }

    if (first.isReverse) {
      final reversals = cards.length;
      final expires = DateTime.now().add(const Duration(seconds: 10));
      timeline.add('${player.name} triggered a kickback.');
      nextState = nextState.copyWith(
        cancelWindow: CancelWindow(
          type: CancelType.kick,
          initiatedBy: player.uid,
          expiresAt: expires,
          effectCount: reversals,
          targetTurnIndex: nextState.advanceIndex(1),
        ),
        statusMessage:
            'Kickback pending. Any player may cancel with a King within 10s.',
      );
      return _completeTurn(nextState);
    }

    if (first.isQuestionCard) {
      final answerRank = cards
          .skipWhile((c) => c.rank == first.rank)
          .map((c) => c.rank.label)
          .first;
      timeline.add(
          '${player.name} asked with ${first.rank.label}s and answered with ${answerRank}s.');
      return _completeTurn(nextState);
    }

    final comboRank = first.rank.label;
    if (cards.length > 1) {
      timeline.add('${player.name} played a $comboRank combo.');
    } else {
      timeline.add('${player.name} played ${first.rank.label}${first.suit.label[0]}.');
    }

    return _completeTurn(nextState);
  }

  GameState _completeTurn(GameState state) {
    final nextIndex = state.advanceIndex(1);
    return state.copyWith(
      turnIndex: nextIndex,
      requiredSuit: state.requiredSuit,
    );
  }
}
