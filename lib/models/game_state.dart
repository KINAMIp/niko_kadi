import 'kadi_card.dart';
import 'kadi_player.dart';

enum CancelType { jump, kick }

const _sentinel = Object();

class AceRequest {
  final Suit suit;
  final Rank rank;
  final String requestedBy;
  final String targetPlayer;

  const AceRequest({
    required this.suit,
    required this.rank,
    required this.requestedBy,
    required this.targetPlayer,
  });

  String get label => '${rank.label}${suit == Suit.joker ? '' : suit.label[0]}';

  AceRequest copyWith({
    Suit? suit,
    Rank? rank,
    String? requestedBy,
    String? targetPlayer,
  }) =>
      AceRequest(
        suit: suit ?? this.suit,
        rank: rank ?? this.rank,
        requestedBy: requestedBy ?? this.requestedBy,
        targetPlayer: targetPlayer ?? this.targetPlayer,
      );

  Map<String, dynamic> toJson() => {
        'suit': suit.name,
        'rank': rank.name,
        'requestedBy': requestedBy,
        'targetPlayer': targetPlayer,
      };

  factory AceRequest.fromJson(Map<String, dynamic> json) => AceRequest(
        suit: Suit.values.firstWhere((e) => e.name == json['suit'] as String),
        rank: Rank.values.firstWhere((e) => e.name == json['rank'] as String),
        requestedBy: json['requestedBy'] as String,
        targetPlayer: json['targetPlayer'] as String,
      );
}

class PenaltyState {
  final int pendingDraw;
  final List<KadiCard> stack;

  const PenaltyState({this.pendingDraw = 0, this.stack = const []});

  bool get isActive => pendingDraw > 0;

  KadiCard? get lastPenalty => stack.isEmpty ? null : stack.last;

  PenaltyState copyWith({int? pendingDraw, List<KadiCard>? stack}) => PenaltyState(
        pendingDraw: pendingDraw ?? this.pendingDraw,
        stack: stack ?? List<KadiCard>.from(this.stack),
      );

  Map<String, dynamic> toJson() => {
        'pendingDraw': pendingDraw,
        'stack': stack.map((e) => e.toJson()).toList(),
      };

  factory PenaltyState.fromJson(Map<String, dynamic> json) => PenaltyState(
        pendingDraw: (json['pendingDraw'] ?? 0) as int,
        stack: (json['stack'] as List<dynamic>? ?? [])
            .map((e) => KadiCard.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

class CancelWindow {
  final CancelType type;
  final String initiatedBy;
  final DateTime expiresAt;
  final int effectCount;
  final int targetTurnIndex;

  const CancelWindow({
    required this.type,
    required this.initiatedBy,
    required this.expiresAt,
    required this.effectCount,
    required this.targetTurnIndex,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  CancelWindow copyWith({
    CancelType? type,
    String? initiatedBy,
    DateTime? expiresAt,
    int? effectCount,
    int? targetTurnIndex,
  }) =>
      CancelWindow(
        type: type ?? this.type,
        initiatedBy: initiatedBy ?? this.initiatedBy,
        expiresAt: expiresAt ?? this.expiresAt,
        effectCount: effectCount ?? this.effectCount,
        targetTurnIndex: targetTurnIndex ?? this.targetTurnIndex,
      );

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'initiatedBy': initiatedBy,
        'expiresAt': expiresAt.toIso8601String(),
        'effectCount': effectCount,
        'targetTurnIndex': targetTurnIndex,
      };

  factory CancelWindow.fromJson(Map<String, dynamic> json) => CancelWindow(
        type: CancelType.values.firstWhere((e) => e.name == json['type'] as String),
        initiatedBy: json['initiatedBy'] as String,
        expiresAt: DateTime.parse(json['expiresAt'] as String),
        effectCount: (json['effectCount'] ?? 0) as int,
        targetTurnIndex: (json['targetTurnIndex'] ?? 0) as int,
      );
}

class PendingWin {
  final String playerId;
  final List<KadiCard> finalCards;
  final Set<String> confirmedBy;

  const PendingWin({
    required this.playerId,
    required this.finalCards,
    this.confirmedBy = const {},
  });

  PendingWin copyWith({
    String? playerId,
    List<KadiCard>? finalCards,
    Set<String>? confirmedBy,
  }) =>
      PendingWin(
        playerId: playerId ?? this.playerId,
        finalCards: finalCards ?? List<KadiCard>.from(this.finalCards),
        confirmedBy: confirmedBy ?? Set<String>.from(this.confirmedBy),
      );

  Map<String, dynamic> toJson() => {
        'playerId': playerId,
        'finalCards': finalCards.map((e) => e.toJson()).toList(),
        'confirmedBy': confirmedBy.toList(),
      };

  factory PendingWin.fromJson(Map<String, dynamic> json) => PendingWin(
        playerId: json['playerId'] as String,
        finalCards: (json['finalCards'] as List<dynamic>? ?? [])
            .map((e) => KadiCard.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        confirmedBy: Set<String>.from(json['confirmedBy'] as List<dynamic>? ?? []),
      );
}

class GameState {
  final String id;
  final List<KadiPlayer> players;
  final List<KadiCard> drawPile;
  final List<KadiCard> discardPile;
  final int turnIndex;
  final int direction;
  final String gameStatus;
  final DateTime createdAt;
  final int maxPlayers;
  final bool isPublic;
  final PenaltyState penaltyState;
  final AceRequest? aceRequest;
  final Suit? requiredSuit;
  final KadiCard? overrideTopCard;
  final CancelWindow? cancelWindow;
  final List<String> eventLog;
  final Set<String> nikoKadiDeclared;
  final PendingWin? pendingWin;
  final String? statusMessage;

  const GameState({
    required this.id,
    required this.players,
    required this.drawPile,
    required this.discardPile,
    required this.turnIndex,
    required this.direction,
    required this.gameStatus,
    required this.createdAt,
    required this.maxPlayers,
    this.isPublic = false,
    this.penaltyState = const PenaltyState(),
    this.aceRequest,
    this.requiredSuit,
    this.overrideTopCard,
    this.cancelWindow,
    this.eventLog = const [],
    this.nikoKadiDeclared = const {},
    this.pendingWin,
    this.statusMessage,
  });

  KadiCard? get topCard =>
      overrideTopCard ?? (discardPile.isEmpty ? null : discardPile.last);

  KadiPlayer get currentPlayer => players[turnIndex % players.length];

  int get playerCount => players.length;

  bool get isWaitingForCancel => cancelWindow != null;

  GameState copyWith({
    List<KadiPlayer>? players,
    List<KadiCard>? drawPile,
    List<KadiCard>? discardPile,
    int? turnIndex,
    int? direction,
    String? gameStatus,
    int? maxPlayers,
    bool? isPublic,
    PenaltyState? penaltyState,
    Object? aceRequest = _sentinel,
    Object? requiredSuit = _sentinel,
    Object? overrideTopCard = _sentinel,
    Object? cancelWindow = _sentinel,
    List<String>? eventLog,
    Object? nikoKadiDeclared = _sentinel,
    Object? pendingWin = _sentinel,
    Object? statusMessage = _sentinel,
  }) =>
      GameState(
        id: id,
        players: players ?? this.players.map((e) => e.copyWith()).toList(),
        drawPile: drawPile ?? List<KadiCard>.from(this.drawPile),
        discardPile: discardPile ?? List<KadiCard>.from(this.discardPile),
        turnIndex: turnIndex ?? this.turnIndex,
        direction: direction ?? this.direction,
        gameStatus: gameStatus ?? this.gameStatus,
        createdAt: createdAt,
        maxPlayers: maxPlayers ?? this.maxPlayers,
        isPublic: isPublic ?? this.isPublic,
        penaltyState: penaltyState ?? this.penaltyState,
        aceRequest: identical(aceRequest, _sentinel)
            ? this.aceRequest
            : aceRequest as AceRequest?,
        requiredSuit: identical(requiredSuit, _sentinel)
            ? this.requiredSuit
            : requiredSuit as Suit?,
        overrideTopCard: identical(overrideTopCard, _sentinel)
            ? this.overrideTopCard
            : overrideTopCard as KadiCard?,
        cancelWindow: identical(cancelWindow, _sentinel)
            ? this.cancelWindow
            : cancelWindow as CancelWindow?,
        eventLog: eventLog ?? List<String>.from(this.eventLog),
        nikoKadiDeclared: identical(nikoKadiDeclared, _sentinel)
            ? Set<String>.from(this.nikoKadiDeclared)
            : (nikoKadiDeclared == null
                ? <String>{}
                : Set<String>.from(nikoKadiDeclared as Set<String>)),
        pendingWin: identical(pendingWin, _sentinel)
            ? this.pendingWin
            : pendingWin as PendingWin?,
        statusMessage: identical(statusMessage, _sentinel)
            ? this.statusMessage
            : statusMessage as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'players': players.map((e) => e.toJson()).toList(),
        'drawPile': drawPile.map((e) => e.toJson()).toList(),
        'discardPile': discardPile.map((e) => e.toJson()).toList(),
        'turnIndex': turnIndex,
        'direction': direction,
        'gameStatus': gameStatus,
        'createdAt': createdAt.toIso8601String(),
        'maxPlayers': maxPlayers,
        'isPublic': isPublic,
        'penaltyState': penaltyState.toJson(),
        'aceRequest': aceRequest?.toJson(),
        'requiredSuit': requiredSuit?.name,
        'overrideTopCard': overrideTopCard?.toJson(),
        'cancelWindow': cancelWindow?.toJson(),
        'eventLog': eventLog,
        'nikoKadiDeclared': nikoKadiDeclared.toList(),
        'pendingWin': pendingWin?.toJson(),
        'statusMessage': statusMessage,
      };

  factory GameState.fromJson(Map<String, dynamic> json) => GameState(
        id: json['id'] as String,
        players: (json['players'] as List<dynamic>? ?? [])
            .map((e) => KadiPlayer.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        drawPile: (json['drawPile'] as List<dynamic>? ?? [])
            .map((e) => KadiCard.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        discardPile: (json['discardPile'] as List<dynamic>? ?? [])
            .map((e) => KadiCard.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        turnIndex: (json['turnIndex'] ?? 0) as int,
        direction: (json['direction'] ?? 1) as int,
        gameStatus: json['gameStatus'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        maxPlayers: (json['maxPlayers'] ?? 2) as int,
        isPublic: (json['isPublic'] ?? false) as bool,
        penaltyState: json['penaltyState'] == null
            ? const PenaltyState()
            : PenaltyState.fromJson(
                Map<String, dynamic>.from(json['penaltyState'] as Map)),
        aceRequest: json['aceRequest'] == null
            ? null
            : AceRequest.fromJson(
                Map<String, dynamic>.from(json['aceRequest'] as Map)),
        requiredSuit: json['requiredSuit'] == null
            ? null
            : Suit.values
                .firstWhere((e) => e.name == json['requiredSuit'] as String),
        overrideTopCard: json['overrideTopCard'] == null
            ? null
            : KadiCard.fromJson(
                Map<String, dynamic>.from(json['overrideTopCard'] as Map)),
        cancelWindow: json['cancelWindow'] == null
            ? null
            : CancelWindow.fromJson(
                Map<String, dynamic>.from(json['cancelWindow'] as Map)),
        eventLog: (json['eventLog'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        nikoKadiDeclared:
            Set<String>.from(json['nikoKadiDeclared'] as List<dynamic>? ?? []),
        pendingWin: json['pendingWin'] == null
            ? null
            : PendingWin.fromJson(
                Map<String, dynamic>.from(json['pendingWin'] as Map)),
        statusMessage: json['statusMessage'] as String?,
      );

  int advanceIndex([int steps = 1]) {
    if (players.isEmpty) return 0;
    final raw = (turnIndex + direction * steps) % players.length;
    return raw < 0 ? raw + players.length : raw;
  }

  GameState withTurn(int newIndex) => copyWith(turnIndex: newIndex % players.length);

  GameState withDirection(int newDirection) => copyWith(direction: newDirection);

  GameState appendLog(String entry) => copyWith(eventLog: [...eventLog, entry]);

  GameState clearPrompt() => copyWith(statusMessage: null);
}
