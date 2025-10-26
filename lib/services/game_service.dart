import 'dart:async';
import 'dart:math';

import '../engine/rule_engine.dart';
import '../models/game_state.dart';
import '../models/kadi_card.dart';
import '../models/kadi_player.dart';

class GameService {
  static final GameService _instance = GameService._internal();
  factory GameService() => _instance;
  GameService._internal();

  final RuleEngine _engine = const RuleEngine();
  final Random _random = Random();

  final _rooms = <String, _Room>{};
  final _controllers = <String, StreamController<GameState>>{};

  Stream<GameState> watch(String gameId) {
    _controllers.putIfAbsent(
      gameId,
      () => StreamController<GameState>.broadcast(),
    );
    final controller = _controllers[gameId]!;
    final room = _rooms[gameId];
    if (room != null) {
      Future.microtask(() => controller.add(room.state));
    }
    return controller.stream;
  }

  GameState? getState(String gameId) => _rooms[gameId]?.state;

  GameState createGame({
    required String id,
    required String hostUid,
    required String hostName,
    int maxPlayers = 4,
    bool isPublic = false,
  }) {
    final host = KadiPlayer(uid: hostUid, name: hostName, hand: []);
    final state = GameState(
      id: id,
      players: [host],
      drawPile: const [],
      discardPile: const [],
      turnIndex: 0,
      direction: 1,
      gameStatus: 'waiting',
      createdAt: DateTime.now(),
      maxPlayers: maxPlayers,
      isPublic: isPublic,
      eventLog: ['Room created by $hostName'],
      statusMessage: 'Waiting for players...',
    );
    final room = _Room(state: state, isPublic: isPublic);
    _rooms[id] = room;
    _emit(room, state);
    return state;
  }

  void addPlayer(String gameId, {required String uid, required String name}) {
    final room = _rooms[gameId];
    if (room == null) return;
    final state = room.state;
    if (state.players.any((p) => p.uid == uid)) return;
    if (state.players.length >= state.maxPlayers) return;

    final players = List<KadiPlayer>.from(state.players)
      ..add(KadiPlayer(uid: uid, name: name, hand: []));

    var updated = state.copyWith(
      players: players,
      eventLog: [...state.eventLog, '$name joined the room'],
      statusMessage: state.gameStatus == 'waiting'
          ? 'Waiting for players...'
          : state.statusMessage,
    );
    room.state = updated;
    _emit(room, updated);
  }

  void startGame(String gameId) {
    final room = _rooms[gameId];
    if (room == null) return;
    var state = room.state;
    if (state.gameStatus == 'playing') return;
    if (state.players.length < 2) return;

    final deck = KadiCard.fullDeck();
    final players = <KadiPlayer>[];
    for (final player in state.players) {
      final hand = <KadiCard>[];
      for (var i = 0; i < 7; i++) {
        hand.add(deck.removeLast());
      }
      players.add(player.copyWith(hand: hand));
    }

    KadiCard starter = deck.removeLast();
    final drawPile = deck;
    final discardPile = <KadiCard>[starter];

    // ensure starter is ordinary; if not, keep drawing until we find one.
    while (!starter.isOrdinary) {
      drawPile.insert(0, starter);
      if (drawPile.isEmpty) break;
      starter = drawPile.removeLast();
    }
    discardPile
      ..clear()
      ..add(starter);

    state = state.copyWith(
      players: players,
      drawPile: drawPile,
      discardPile: discardPile,
      gameStatus: 'playing',
      turnIndex: 0,
      direction: 1,
      penaltyState: const PenaltyState(),
      aceRequest: null,
      requiredSuit: null,
      overrideTopCard: null,
      eventLog: [
        ...state.eventLog,
        'Game started. ${players.first.name} begins.',
      ],
      statusMessage: '${players.first.name}, it\'s your turn.',
    );

    room.state = state;
    _emit(room, state);
  }

  void playCards(
    String gameId, {
    required String playerId,
    required List<String> cardIds,
    Suit? requestedSuit,
    Rank? requestedRank,
  }) {
    final room = _rooms[gameId];
    if (room == null) return;
    _resolveExpiredWindow(room);
    var state = room.state;
    if (state.gameStatus != 'playing') return;

    final playerIndex = state.players.indexWhere((p) => p.uid == playerId);
    if (playerIndex == -1) return;
    final player = state.players[playerIndex];
    final handIndex = {for (final card in player.hand) card.id: card};
    final cards = <KadiCard>[];
    for (final id in cardIds) {
      final card = handIndex[id];
      if (card == null) {
        return;
      }
      cards.add(card);
    }

    if (cards.isEmpty) {
      return;
    }

    AceRequestPayload? request;
    if (cards.first.isAceOfSpades) {
      if (requestedSuit == null || requestedRank == null) {
        return;
      }
      request = AceRequestPayload(suit: requestedSuit, rank: requestedRank);
    }

    final outcome = _engine.play(
      state,
      PlayIntent(playerId: playerId, cards: cards, aceRequest: request),
    );
    if (!outcome.isValid || outcome.state == null) {
      return;
    }

    var updated = outcome.state!;
    for (final entry in outcome.timeline) {
      updated = updated.appendLog(entry);
    }

    updated = _handlePostPlay(updated, playerId, cards);

    if (updated.gameStatus == 'playing' &&
        updated.statusMessage == null &&
        !updated.isWaitingForCancel) {
      final current = updated.players[updated.turnIndex];
      updated = updated.copyWith(
        statusMessage: '${current.name}, it\'s your turn.',
      );
    }

    room.state = updated;
    _emit(room, updated);
  }

  void drawCard(String gameId, String playerId, {int count = 1}) {
    final room = _rooms[gameId];
    if (room == null) return;
    _resolveExpiredWindow(room);
    var state = room.state;
    if (state.gameStatus != 'playing') return;
    if (state.cancelWindow != null) return;
    if (state.currentPlayer.uid != playerId) return;
    if (state.penaltyState.isActive) return;
    if (state.aceRequest != null) return;

    final draw = _draw(state, count);
    final players = List<KadiPlayer>.from(state.players);
    final index = players.indexWhere((p) => p.uid == playerId);
    final hand = List<KadiCard>.from(players[index].hand)..addAll(draw.cards);
    players[index] = players[index].copyWith(hand: hand);

    state = state.copyWith(
      players: players,
      drawPile: draw.drawPile,
      discardPile: draw.discardPile,
      eventLog: [...state.eventLog, '${players[index].name} drew $count card(s).'],
    );

    room.state = state;
    _emit(room, state);
  }

  void pickPenalty(String gameId, String playerId) {
    final room = _rooms[gameId];
    if (room == null) return;
    _resolveExpiredWindow(room);
    var state = room.state;
    if (state.gameStatus != 'playing') return;
    if (state.cancelWindow != null) return;
    if (state.currentPlayer.uid != playerId) return;
    if (!state.penaltyState.isActive) return;

    final amount = state.penaltyState.pendingDraw;
    final draw = _draw(state, amount);
    final players = List<KadiPlayer>.from(state.players);
    final index = players.indexWhere((p) => p.uid == playerId);
    final hand = List<KadiCard>.from(players[index].hand)..addAll(draw.cards);
    players[index] = players[index].copyWith(hand: hand);

    final playerName = players[index].name;
    final log = '$playerName picked $amount card(s) from the penalty.';

    final nextIndex = _advanceFrom(state, state.turnIndex, 1);
    state = state.copyWith(
      players: players,
      drawPile: draw.drawPile,
      discardPile: draw.discardPile,
      penaltyState: const PenaltyState(),
      eventLog: [...state.eventLog, log],
      turnIndex: nextIndex,
      statusMessage:
          '${players[nextIndex].name}, match the pile to continue.',
    );

    room.state = state;
    _emit(room, state);
  }

  void failAceRequest(String gameId, String playerId) {
    final room = _rooms[gameId];
    if (room == null) return;
    _resolveExpiredWindow(room);
    var state = room.state;
    if (state.gameStatus != 'playing') return;
    if (state.cancelWindow != null) return;
    final request = state.aceRequest;
    if (request == null || request.targetPlayer != playerId) return;

    final draw = _draw(state, 1);
    final players = List<KadiPlayer>.from(state.players);
    final index = players.indexWhere((p) => p.uid == playerId);
    final hand = List<KadiCard>.from(players[index].hand)..addAll(draw.cards);
    players[index] = players[index].copyWith(hand: hand);

    final nextIndex = _advanceFrom(state, state.turnIndex, 1);
    state = state.copyWith(
      players: players,
      drawPile: draw.drawPile,
      discardPile: draw.discardPile,
      aceRequest: null,
      turnIndex: nextIndex,
      eventLog: [
        ...state.eventLog,
        '${players[index].name} drew 1 card after missing the request.',
      ],
      statusMessage:
          '${players[nextIndex].name}, match the pile to continue.',
    );

    room.state = state;
    _emit(room, state);
  }

  void cancelWindowWithCard(String gameId, String playerId, String cardId) {
    final room = _rooms[gameId];
    if (room == null) return;
    _resolveExpiredWindow(room);
    var state = room.state;
    final window = state.cancelWindow;
    if (window == null) return;
    if (window.initiatedBy == playerId) return;

    final playerIndex = state.players.indexWhere((p) => p.uid == playerId);
    if (playerIndex == -1) return;
    final player = state.players[playerIndex];
    KadiCard? card;
    for (final c in player.hand) {
      if (c.id == cardId) {
        card = c;
        break;
      }
    }
    if (card == null) return;

    if (window.type == CancelType.jump && !card.isSkip) {
      return;
    }
    if (window.type == CancelType.kick && !card.isReverse) {
      return;
    }

    final players = List<KadiPlayer>.from(state.players);
    final hand = List<KadiCard>.from(player.hand)
      ..removeWhere((c) => c.id == cardId);
    players[playerIndex] = player.copyWith(hand: hand);

    final discard = List<KadiCard>.from(state.discardPile)..add(card);

    var log = '';
    if (window.type == CancelType.jump) {
      log = '${player.name} canceled the jump.';
    } else {
      log = '${player.name} canceled the kickback.';
    }

    final nextIndex = _advanceFrom(state, playerIndex, 1);
    state = state.copyWith(
      players: players,
      discardPile: discard,
      cancelWindow: null,
      turnIndex: nextIndex,
      eventLog: [...state.eventLog, log],
      statusMessage: '${players[nextIndex].name}, it\'s your turn.',
    );

    room.state = state;
    _emit(room, state);
  }

  void declareNikoKadi(String gameId, String playerId) {
    final room = _rooms[gameId];
    if (room == null) return;
    var state = room.state;
    final index = state.players.indexWhere((p) => p.uid == playerId);
    if (index == -1) return;
    final player = state.players[index];
    if (!_handEligibleForNiko(player)) return;

    final declared = Set<String>.from(state.nikoKadiDeclared)..add(playerId);
    state = state.copyWith(
      nikoKadiDeclared: declared,
      eventLog: [...state.eventLog, '${player.name} announced "Niko Kadi"'],
      statusMessage: '${player.name} is ready to win on the next turn.',
    );
    room.state = state;
    _emit(room, state);
  }

  void confirmWin(String gameId, String playerId) {
    final room = _rooms[gameId];
    if (room == null) return;
    var state = room.state;
    final pending = state.pendingWin;
    if (pending == null) return;

    final confirmations = Set<String>.from(pending.confirmedBy)..add(playerId);
    final confirmerName = state.players
        .firstWhere(
          (p) => p.uid == playerId,
          orElse: () => KadiPlayer(uid: playerId, name: playerId, hand: []),
        )
        .name;

    state = state.copyWith(
      pendingWin: pending.copyWith(confirmedBy: confirmations),
      eventLog: [...state.eventLog, '$confirmerName confirmed the win.'],
    );

    if (confirmations.length == state.players.length) {
      state = state.copyWith(
        gameStatus: 'closed',
        statusMessage: 'Round finished. Returning to lobby shortly.',
        eventLog: [...state.eventLog, 'All players confirmed the win.'],
      );
    }

    room.state = state;
    _emit(room, state);
  }

  void _resolveExpiredWindow(_Room room) {
    var state = room.state;
    final window = state.cancelWindow;
    if (window == null || !window.isExpired) return;

    switch (window.type) {
      case CancelType.jump:
        final skip = window.effectCount;
        var index = window.targetTurnIndex;
        for (var i = 0; i < skip; i++) {
          index = _advanceFrom(state, index, 1);
        }
        final nextName = state.players[index].name;
        state = state.copyWith(
          cancelWindow: null,
          turnIndex: index,
          eventLog: [
            ...state.eventLog,
            'Jump resolved automatically. Skipped $skip player(s).',
          ],
          statusMessage: '$nextName, it\'s your turn.',
        );
        break;
      case CancelType.kick:
        var direction = state.direction;
        if (window.effectCount.isOdd) {
          direction = -direction;
        }
        final initiatorIndex =
            state.players.indexWhere((p) => p.uid == window.initiatedBy);
        final startIndex = initiatorIndex == -1 ? state.turnIndex : initiatorIndex;
        final nextIndex = _advanceFrom(state, startIndex, 1,
            directionOverride: direction);
        final nextName = state.players[nextIndex].name;
        state = state.copyWith(
          cancelWindow: null,
          direction: direction,
          turnIndex: nextIndex,
          eventLog: [
            ...state.eventLog,
            direction == 1
                ? 'Kickback expired. Direction stays clockwise.'
                : 'Kickback expired. Direction is now counterclockwise.',
          ],
          statusMessage: '$nextName, it\'s your turn.',
        );
        break;
    }

    room.state = state;
    _emit(room, state);
  }

  void _emit(_Room room, GameState state) {
    room.state = state;
    _controllers.putIfAbsent(
      state.id,
      () => StreamController<GameState>.broadcast(),
    );
    _controllers[state.id]!.add(state);
  }

  ({List<KadiCard> cards, List<KadiCard> drawPile, List<KadiCard> discardPile})
      _draw(GameState state, int count) {
    final drawPile = List<KadiCard>.from(state.drawPile);
    final discardPile = List<KadiCard>.from(state.discardPile);
    final drawn = <KadiCard>[];

    for (var i = 0; i < count; i++) {
      if (drawPile.isEmpty) {
        if (discardPile.length <= 1) break;
        final top = discardPile.removeLast();
        drawPile
          ..addAll(discardPile)
          ..shuffle(_random);
        discardPile
          ..clear()
          ..add(top);
      }
      drawn.add(drawPile.removeLast());
    }

    return (cards: drawn, drawPile: drawPile, discardPile: discardPile);
  }

  GameState _handlePostPlay(
      GameState state, String playerId, List<KadiCard> cardsPlayed) {
    final index = state.players.indexWhere((p) => p.uid == playerId);
    if (index == -1) return state;
    final player = state.players[index];

    if (player.hand.isEmpty) {
      if (state.nikoKadiDeclared.contains(playerId)) {
        final pending = PendingWin(
          playerId: playerId,
          finalCards: List<KadiCard>.from(cardsPlayed),
          confirmedBy: {playerId},
        );
        state = state.copyWith(
          pendingWin: pending,
          gameStatus: 'finished',
          statusMessage: 'Awaiting confirmation for ${player.name}\'s win.',
          eventLog: [
            ...state.eventLog,
            '${player.name} has gone out and awaits confirmation.',
          ],
        );
      } else {
        state = state.copyWith(
          eventLog: [
            ...state.eventLog,
            '${player.name} emptied their hand without declaring Niko Kadi.',
          ],
          statusMessage:
              '${player.name} must declare before a future winning attempt.',
        );
      }
      return state;
    }

    if (_handEligibleForNiko(player) &&
        !state.nikoKadiDeclared.contains(playerId)) {
      state = state.copyWith(
        statusMessage:
            '${player.name}, you can declare "Niko Kadi" before your next turn.',
      );
    }

    return state;
  }

  bool _handEligibleForNiko(KadiPlayer player) {
    if (player.hand.isEmpty) return false;
    const winningRanks = {
      Rank.four,
      Rank.five,
      Rank.six,
      Rank.seven,
      Rank.nine,
      Rank.ten,
    };
    return player.hand.every((c) => winningRanks.contains(c.rank));
  }

  int _advanceFrom(GameState state, int startIndex, int steps,
      {int? directionOverride}) {
    if (state.players.isEmpty) return 0;
    final total = state.players.length;
    var index = startIndex % total;
    if (index < 0) index += total;
    final direction = directionOverride ?? state.direction;
    for (var i = 0; i < steps; i++) {
      index += direction;
      index %= total;
      if (index < 0) index += total;
    }
    return index;
  }
}

class _Room {
  GameState state;
  final bool isPublic;

  _Room({required this.state, required this.isPublic});
}
