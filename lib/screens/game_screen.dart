import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/achievement.dart';
import '../models/bird.dart';
import '../models/bird_customization.dart';
import '../models/map_data.dart';
import '../models/physics_fact.dart';
import '../models/pipe.dart';
import '../utils/achievement_manager.dart';
import '../utils/particle_system.dart';
import '../utils/sound_manager.dart';
import '../widgets/game_painter.dart';
import '../widgets/physics_fun_fact_widget.dart';
import '../widgets/physics_quiz_dialog.dart';

enum GameState { ready, playing, paused, gameOver }

class GameScreen extends StatefulWidget {
  final String mapKey;
  final MapData mapData;

  const GameScreen({
    super.key,
    required this.mapKey,
    required this.mapData,
  });

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  late Bird bird;
  List<Pipe> pipes = [];
  GameState gameState = GameState.ready;
  Timer? gameTimer;
  int score = 0;
  double pipeSpeed = 2.0; // Starts slow for beginner-friendly pacing
  final Random random = Random();
  bool _initialized = false;

  // Progressive difficulty & Level system
  bool _showLevelUpAlert = false;
  String _levelUpMessage = '';
  Timer? _levelUpTimer;

  int get _currentLevel {
    if (score < 5) return 1;
    if (score < 10) return 2;
    if (score < 20) return 3;
    if (score < 30) return 4;
    return 5;
  }

  String get _currentLevelTitle {
    switch (_currentLevel) {
      case 1:
        return 'WARM UP';
      case 2:
        return 'CASUAL';
      case 3:
        return 'NORMAL';
      case 4:
        return 'HARD';
      default:
        return 'INSANE';
    }
  }

  Color _getLevelColor() {
    switch (_currentLevel) {
      case 1:
        return const Color(0xFF00E676);
      case 2:
        return const Color(0xFF00E5FF);
      case 3:
        return const Color(0xFFFFD600);
      case 4:
        return const Color(0xFFFF9100);
      default:
        return const Color(0xFFFF1744);
    }
  }

  double get _currentPipeSpeed {
    switch (_currentLevel) {
      case 1:
        return 1.5; // Very relaxed, leisurely cruise
      case 2:
        return 2.0;
      case 3:
        return 2.6;
      case 4:
        return 3.3;
      default:
        return min(4.2, 3.3 + (score - 29) * 0.04);
    }
  }

  double get _currentPipeGap {
    switch (_currentLevel) {
      case 1:
        return 310.0; // Huge 310px gap - super easy to fly through
      case 2:
        return 270.0;
      case 3:
        return 235.0;
      case 4:
        return 200.0;
      default:
        return max(175.0, 200.0 - (score - 29) * 0.8);
    }
  }

  double get _currentPipeSpacing {
    switch (_currentLevel) {
      case 1:
        return 420.0; // Lots of distance between pipes
      case 2:
        return 360.0;
      case 3:
        return 320.0;
      case 4:
        return 290.0;
      default:
        return 270.0;
    }
  }

  double get _currentGravityFactor {
    switch (_currentLevel) {
      case 1:
        return 0.14; // Ultra-gentle Moon-like float
      case 2:
        return 0.26;
      case 3:
        return 0.45;
      case 4:
        return 0.70;
      default:
        return 1.0;
    }
  }

  double get _currentFlapVelocity {
    // Small, controlled hop so the bird never launches too high
    final ratio = (bird.flapStrength / -15.0).clamp(0.85, 1.15);
    switch (_currentLevel) {
      case 1:
        return -4.6 * ratio; // Short, controlled hop (~20px lift)
      case 2:
        return -5.6 * ratio;
      case 3:
        return -6.8 * ratio;
      case 4:
        return -8.0 * ratio;
      default:
        return -9.5 * ratio;
    }
  }

  double get _currentMaxFallSpeed {
    switch (_currentLevel) {
      case 1:
        return 4.0; // Very slow descent - never plunges
      case 2:
        return 5.4;
      case 3:
        return 7.2;
      case 4:
        return 9.5;
      default:
        return 15.0;
    }
  }

  void _triggerLevelUp(int level, String title) {
    soundManager.playAchievement();
    setState(() {
      _levelUpMessage = 'LEVEL $level: $title!';
      _showLevelUpAlert = true;
    });
    _levelUpTimer?.cancel();
    _levelUpTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) {
        setState(() {
          _showLevelUpAlert = false;
        });
      }
    });
  }

  // New feature managers
  final ParticleSystem particleSystem = ParticleSystem();
  final AchievementManager achievementManager = AchievementManager();
  final SoundManager soundManager = SoundManager();
  List<Achievement> newAchievements = [];
  bool usedPause = false;
  bool _audioStarted = false;
  double backgroundOffset = 0; // For scrolling background
  BirdCustomization? _birdCustomization;
  bool hasUsedRevival = false; // Track if player already used quiz revival

  // Immunity system for revival
  bool isImmune = false;
  Timer? immunityTimer;
  int immunityDurationSeconds = 5;

  // Physics fun fact for display
  PhysicsFact? _currentFunFact;

  @override
  void initState() {
    super.initState();
    // Initialize managers
    achievementManager.loadProgress();
    soundManager.initialize();
    _loadBirdCustomization();
    // Don't call _initGame here - it needs context
  }

  Future<void> _loadBirdCustomization() async {
    final customization = await BirdCustomization.load();
    setState(() {
      _birdCustomization = customization;
      // Reinitialize bird if game was already initialized with wrong type
      if (_initialized) {
        bird = Bird.withType(
          x: 100,
          y: MediaQuery.of(context).size.height / 2,
          birdType: _birdCustomization?.birdIndex ?? 0,
        );
      }
    });
  }

  Future<void> _startAudioIfNeeded() async {
    if (!_audioStarted) {
      await soundManager
          .playGameMusic(); // Switch to ukulele music for gameplay
      _audioStarted = true;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Initialize game here where MediaQuery is available
    if (!_initialized) {
      _initGame();
      _initialized = true;
    }
  }

  void _initGame() {
    bird = Bird.withType(
      x: 100,
      y: MediaQuery.of(context).size.height / 2,
      birdType: _birdCustomization?.birdIndex ?? 0,
    );
    pipes.clear();
    score = 0;
    pipeSpeed = 1.5;
    _showLevelUpAlert = false;
    _levelUpTimer?.cancel();
    gameState = GameState.ready;
    hasUsedRevival = false; // Reset revival flag for new game
    isImmune = false; // Reset immunity flag
    immunityTimer?.cancel(); // Cancel any pending immunity timers
  }

  void _startGame() {
    if (gameState != GameState.ready) return;

    // Start game music (ukulele) when gameplay begins
    _startAudioIfNeeded();

    setState(() {
      gameState = GameState.playing;
    });

    // Generate initial pipe with generous starting runway
    _generatePipes(MediaQuery.of(context).size.width + 120.0);

    // Game loop - 60 FPS
    gameTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (gameState == GameState.playing) {
        _update();
      }
    });
  }

  void _update() {
    setState(() {
      // Dynamic pipe speed based on level/score
      pipeSpeed = _currentPipeSpeed;

      // Update bird physics with gentle early gravity scaling (Moon-like float)
      final calculatedGravity =
          widget.mapData.gravityPixels * _currentGravityFactor;
      final effectiveGravity = calculatedGravity.clamp(0.24, 1.8);
      bird.update(effectiveGravity, _currentMaxFallSpeed);

      // Scroll background
      backgroundOffset +=
          pipeSpeed * 0.5; // Scroll at half the pipe speed for parallax effect

      // Reset when scrolled one full image width for seamless loop
      // Image aspect ratio is 1536:672, so width = height * 2.286
      final imageWidth = MediaQuery.of(context).size.height * (1536 / 672);
      if (backgroundOffset >= imageWidth) {
        backgroundOffset -= imageWidth;
      }

      // Update pipes
      for (var pipe in pipes) {
        pipe.update(pipeSpeed);

        // Check if bird passed the pipe
        if (!pipe.passed && bird.x > pipe.x + pipe.width) {
          pipe.passed = true;
          final prevLevel = _currentLevel;
          score++;
          // Play score sound
          soundManager.playScore();

          // Check if player reached a new level
          if (_currentLevel > prevLevel) {
            _triggerLevelUp(_currentLevel, _currentLevelTitle);
          }
        }
      }

      // Remove off-screen pipes and generate new ones with dynamic spacing
      pipes.removeWhere((pipe) => pipe.isOffScreen());
      if (pipes.isEmpty ||
          pipes.last.x <
              MediaQuery.of(context).size.width - _currentPipeSpacing) {
        _generatePipes();
      }

      // Check collisions (skip if immune)
      if (!isImmune && _checkCollision()) {
        _gameOver();
      }

      // Soft ceiling clamp: prevent bird from flying off-screen without dying
      if (bird.y < bird.size / 2) {
        bird.y = bird.size / 2;
        if (bird.velocity < 0) {
          bird.velocity = 0;
        }
      }

      // Check if bird hits the ground / bottom
      if (!isImmune &&
          bird.y > MediaQuery.of(context).size.height - bird.size / 2) {
        _gameOver();
      }
    });
  }

  void _generatePipes([double? spawnX]) {
    final screenHeight = MediaQuery.of(context).size.height;
    final currentGap = _currentPipeGap;

    // Centered gaps for early levels (Warm Up / Casual) so player doesn't have to make extreme vertical moves
    final double gapY;
    if (_currentLevel == 1) {
      final center = screenHeight * 0.48;
      gapY = center + (random.nextDouble() - 0.5) * 60.0;
    } else if (_currentLevel == 2) {
      final center = screenHeight * 0.48;
      gapY = center + (random.nextDouble() - 0.5) * 120.0;
    } else {
      const minGapY = 160.0;
      final maxGapY = screenHeight - 160.0;
      gapY = minGapY + random.nextDouble() * (maxGapY - minGapY);
    }

    pipes.add(Pipe(
      x: spawnX ?? MediaQuery.of(context).size.width,
      gapY: gapY,
      gapHeight: currentGap,
    ));
  }

  bool _checkCollision() {
    final birdRect = bird.getCollisionRect();
    final screenHeight = MediaQuery.of(context).size.height;

    for (var pipe in pipes) {
      final topRect = pipe.getTopRect(screenHeight);
      final bottomRect = pipe.getBottomRect(screenHeight);

      if (birdRect.overlaps(topRect) || birdRect.overlaps(bottomRect)) {
        return true;
      }
    }
    return false;
  }

  void _gameOver() {
    gameTimer?.cancel();

    // Create explosion effect at bird position
    particleSystem.createExplosion(bird.x, bird.y, color: Colors.red);

    // Play hit sound
    soundManager.playHit();

    // Check achievements
    newAchievements =
        achievementManager.checkAchievements(widget.mapKey, score, usedPause);

    // Play achievement sound if any unlocked
    if (newAchievements.isNotEmpty) {
      soundManager.playAchievement();
    }

    // Generate a fun fact for game over screen
    _currentFunFact = PhysicsFactDatabase.getRandomFact();

    setState(() {
      gameState = GameState.gameOver;
    });

    // Show quiz revival dialog if not already used in this game
    if (!hasUsedRevival) {
      _showQuizRevivalDialog();
    }
  }

  void _flap() {
    if (gameState == GameState.ready) {
      _startGame();
    }

    if (gameState == GameState.playing) {
      setState(() {
        bird.flap(_currentFlapVelocity);
        // Add particle trail effect
        particleSystem.createTrail(
          bird.x + 20,
          bird.y + 20,
        );
        // Play flap sound
        soundManager.playFlap();
      });
    }
  }

  void _pause() {
    if (gameState == GameState.playing) {
      gameTimer?.cancel();
      soundManager.pauseBackgroundMusic();
      setState(() {
        gameState = GameState.paused;
        // Generate a fun fact when pausing
        _currentFunFact = PhysicsFactDatabase.getRandomFact();
      });
    }
  }

  void _resume() {
    if (gameState == GameState.paused) {
      soundManager.resumeBackgroundMusic();
      setState(() {
        gameState = GameState.playing;
      });
      // Restart the game timer to continue updates
      gameTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
        if (gameState == GameState.playing) {
          _update();
        }
      });
    }
  }

  void _restart() {
    gameTimer?.cancel();
    _initGame();
    // Automatically start the game without requiring tap
    setState(() {
      gameState = GameState.playing;
    });
    // Generate initial pipes
    _generatePipes();
    // Start game loop immediately
    gameTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (gameState == GameState.playing) {
        _update();
      }
    });
  }

  void _showQuizRevivalDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PhysicsQuizDialog(
        soundManager: soundManager,
        onRevive: _reviveBird,
        onGameEnd: () {
          setState(() {
            gameState = GameState.gameOver;
          });
        },
      ),
    );
  }

  void _reviveBird() {
    setState(() {
      hasUsedRevival = true;
      gameState = GameState.playing;
      // Reset bird position and velocity
      bird.reset(MediaQuery.of(context).size.height);

      // Activate immunity for 5 seconds
      isImmune = true;
    });

    // Start immunity timer
    immunityTimer?.cancel();
    immunityTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      final elapsedSeconds = timer.tick * 0.1;

      if (elapsedSeconds >= immunityDurationSeconds) {
        timer.cancel();
        setState(() {
          isImmune = false;
        });
      }
    });

    // Restart game loop
    gameTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (gameState == GameState.playing) {
        _update();
      }
    });
  }

  @override
  void dispose() {
    gameTimer?.cancel();
    immunityTimer?.cancel();
    _levelUpTimer?.cancel();
    soundManager.stopBackgroundMusic();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      body: GestureDetector(
        onTap: _flap,
        child: Stack(
          children: [
            // Scrolling Background Image - optimized for 1536x672 panoramic images
            Container(
              width: size.width,
              height: size.height,
              color: widget.mapData.backgroundColor,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Calculate width needed to show full image height without cropping
                  const imageAspectRatio = 1536 / 672; // 2.286:1
                  final imageWidth = constraints.maxHeight * imageAspectRatio;

                  // Create seamless loop with blended edges
                  final normalizedOffset = backgroundOffset % imageWidth;
                  const blendWidth = 100.0; // Width of blend zone

                  return ClipRect(
                    child: Stack(
                      children: [
                        // Main repeating images
                        ...List.generate(3, (index) {
                          return Positioned(
                            left: (index * imageWidth) - normalizedOffset,
                            top: 0,
                            child: Image.asset(
                              widget.mapData.backgroundImage,
                              width: imageWidth,
                              height: constraints.maxHeight,
                              fit: BoxFit.fitHeight,
                            ),
                          );
                        }),
                        // Blend zones to hide seams
                        ...List.generate(3, (index) {
                          final leftEdge =
                              (index * imageWidth) - normalizedOffset;
                          return Positioned(
                            left: leftEdge - blendWidth / 2,
                            top: 0,
                            width: blendWidth,
                            height: constraints.maxHeight,
                            child: ClipRect(
                              child: BackdropFilter(
                                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 0),
                                child: Container(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.centerLeft,
                                      end: Alignment.centerRight,
                                      colors: [
                                        widget.mapData.backgroundColor
                                            .withValues(alpha: 0.3),
                                        Colors.transparent,
                                        widget.mapData.backgroundColor
                                            .withValues(alpha: 0.3),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  );
                },
              ),
            ),
            // Game Canvas (bird and pipes)
            Container(
              color: Colors.transparent,
              child: CustomPaint(
                size: size,
                painter: GamePainter(
                  bird: bird,
                  pipes: pipes,
                  mapData: widget.mapData,
                  birdCustomization: _birdCustomization,
                  isImmune: isImmune,
                ),
              ),
            ),

            // Top UI
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Left group: Map Info + Mute Button
                        Row(
                          children: [
                            // Map Info
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${widget.mapData.icon} ${widget.mapData.name}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    'g = ${widget.mapData.gravity} m/s²',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            // Mute Button
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: IconButton(
                                onPressed: () {
                                  setState(() {
                                    soundManager.toggleMusic();
                                  });
                                },
                                icon: Icon(
                                  soundManager.musicEnabled
                                      ? Icons.volume_up
                                      : Icons.volume_off,
                                  color: Colors.white,
                                  size: 24,
                                ),
                                tooltip: soundManager.musicEnabled
                                    ? 'Mute Music'
                                    : 'Unmute Music',
                              ),
                            ),
                          ],
                        ),

                        // Level Badge & Score Container
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: _getLevelColor().withValues(alpha: 0.85),
                                  width: 1.5,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.bolt,
                                    color: _getLevelColor(),
                                    size: 16,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'LVL $_currentLevel • $_currentLevelTitle',
                                    style: TextStyle(
                                      color: _getLevelColor(),
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    widget.mapData.primaryColor.withValues(alpha: 0.9),
                                    widget.mapData.primaryColor.withValues(alpha: 0.7),
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(25),
                                border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.5), width: 2),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.3),
                                    blurRadius: 10,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.star,
                                    color: Colors.white,
                                    size: 24,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '$score',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 28,
                                      fontWeight: FontWeight.bold,
                                      shadows: [
                                        Shadow(
                                          offset: Offset(1, 1),
                                          blurRadius: 3,
                                          color: Colors.black54,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const Spacer(),

                    // Physics Info Panel
                    if (gameState == GameState.playing)
                      Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                _PhysicsInfo(
                                  label: 'Velocity',
                                  value: bird.velocity.abs().toStringAsFixed(2),
                                  unit: 'm/s',
                                ),
                                _PhysicsInfo(
                                  label: 'Acceleration',
                                  value: bird.acceleration.toStringAsFixed(2),
                                  unit: 'm/s²',
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                    // Control Buttons
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.home),
                          label: const Text('Menu'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.black54,
                            foregroundColor: Colors.white,
                          ),
                        ),
                        ElevatedButton.icon(
                          onPressed: gameState == GameState.playing
                              ? () {
                                  soundManager.playButton();
                                  _pause();
                                }
                              : gameState == GameState.paused
                                  ? () {
                                      soundManager.playButton();
                                      _resume();
                                    }
                                  : null,
                          icon: Icon(
                            gameState == GameState.paused
                                ? Icons.play_arrow
                                : Icons.pause,
                          ),
                          label: Text(
                            gameState == GameState.paused ? 'Resume' : 'Pause',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.black54,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // Level Up Banner
            if (_showLevelUpAlert && gameState == GameState.playing)
              Positioned(
                top: 130,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          _getLevelColor().withValues(alpha: 0.9),
                          _getLevelColor().withValues(alpha: 0.65),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: _getLevelColor().withValues(alpha: 0.5),
                          blurRadius: 15,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.arrow_upward_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _levelUpMessage,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.5,
                            shadows: [
                              Shadow(
                                offset: Offset(1, 1),
                                blurRadius: 4,
                                color: Colors.black54,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Ready Screen
            if (gameState == GameState.ready)
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.3),
                      Colors.black.withValues(alpha: 0.6),
                    ],
                  ),
                ),
                child: Center(
                  child: SingleChildScrollView(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final screenWidth = MediaQuery.of(context).size.width;
                        final isSmallScreen = screenWidth < 380;

                        final iconSize = isSmallScreen ? 48.0 : 60.0;
                        final titleFontSize = isSmallScreen ? 24.0 : 36.0;
                        final mapNameFontSize = isSmallScreen ? 18.0 : 22.0;
                        final mapGravityFontSize = isSmallScreen ? 13.0 : 16.0;
                        final howToPlayFontSize = isSmallScreen ? 14.0 : 16.0;
                        final infoFontSize = isSmallScreen ? 11.0 : 13.0;
                        final spacingSmall = isSmallScreen ? 12.0 : 16.0;
                        final spacingMedium = isSmallScreen ? 16.0 : 24.0;
                        final spacingLarge = isSmallScreen ? 20.0 : 32.0;
                        final containerMargin = isSmallScreen ? 32.0 : 40.0;
                        final containerPadding = isSmallScreen ? 12.0 : 16.0;

                        return Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Animated tap indicator
                            Container(
                              padding: EdgeInsets.all(containerPadding),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withValues(alpha: 0.15),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.3),
                                  width: 3,
                                ),
                              ),
                              child: Icon(
                                Icons.touch_app,
                                size: iconSize,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(height: spacingMedium),
                            Text(
                              'TAP TO START',
                              style: TextStyle(
                                fontSize: titleFontSize,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                letterSpacing: 2,
                                shadows: const [
                                  Shadow(
                                    offset: Offset(2, 2),
                                    blurRadius: 8,
                                    color: Colors.black54,
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(height: spacingSmall),
                            Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: spacingSmall,
                                vertical: containerPadding,
                              ),
                              decoration: BoxDecoration(
                                color: widget.mapData.primaryColor.withValues(alpha: 0.8),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.5),
                                  width: 2,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    '${widget.mapData.icon} ${widget.mapData.name}',
                                    style: TextStyle(
                                      fontSize: mapNameFontSize,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                  SizedBox(height: isSmallScreen ? 2 : 4),
                                  Text(
                                    'Gravity: ${widget.mapData.gravity} m/s²',
                                    style: TextStyle(
                                      fontSize: mapGravityFontSize,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(height: spacingLarge),
                            Container(
                              margin: EdgeInsets.symmetric(horizontal: containerMargin),
                              padding: EdgeInsets.all(containerPadding),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(15),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.3),
                                ),
                              ),
                              child: Column(
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.info_outline,
                                        color: Colors.white70,
                                        size: isSmallScreen ? 18 : 20,
                                      ),
                                      SizedBox(width: spacingSmall),
                                      Text(
                                        'How to Play',
                                        style: TextStyle(
                                          fontSize: howToPlayFontSize,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                  SizedBox(height: containerPadding),
                                  Text(
                                    'Tap to flap and avoid pipes\nExperience different gravity forces!',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: infoFontSize,
                                      color: Colors.white70,
                                      height: 1.4,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),

            // Pause Screen
            if (gameState == GameState.paused)
              Container(
                color: Colors.black45,
                child: Center(
                  child: SingleChildScrollView(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final screenWidth = MediaQuery.of(context).size.width;
                        final isSmallScreen = screenWidth < 380;

                        final titleFontSize = isSmallScreen ? 24.0 : 32.0;
                        final spacingSmall = isSmallScreen ? 12.0 : 16.0;
                        final spacingLarge = isSmallScreen ? 20.0 : 32.0;
                        final buttonPadding = isSmallScreen ? 16.0 : 24.0;
                        final containerMargin = isSmallScreen ? 12.0 : 16.0;

                        return Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.pause_circle,
                              size: isSmallScreen ? 48 : 64,
                              color: Colors.white,
                            ),
                            SizedBox(height: spacingSmall),
                            Text(
                              'Paused',
                              style: TextStyle(
                                fontSize: titleFontSize,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(height: spacingLarge),
                            // Display fun fact if available
                            if (_currentFunFact != null)
                              Padding(
                                padding: EdgeInsets.symmetric(horizontal: containerMargin),
                                child: PhysicsFunFactWidget(
                                  fact: _currentFunFact!,
                                  onDismiss: () {
                                    setState(() {
                                      _currentFunFact =
                                          PhysicsFactDatabase.getRandomFact();
                                    });
                                  },
                                ),
                              ),
                            SizedBox(height: spacingLarge),
                            // Resume and Menu buttons
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: containerMargin),
                              child: isSmallScreen
                                  ? Column(
                                      children: [
                                        SizedBox(
                                          width: double.infinity,
                                          child: ElevatedButton.icon(
                                            onPressed: () => Navigator.pop(context),
                                            icon: const Icon(Icons.home),
                                            label: const Text('Menu'),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.black54,
                                              foregroundColor: Colors.white,
                                              padding: EdgeInsets.symmetric(
                                                horizontal: buttonPadding,
                                                vertical: 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                        SizedBox(height: spacingSmall),
                                        SizedBox(
                                          width: double.infinity,
                                          child: ElevatedButton.icon(
                                            onPressed: () {
                                              soundManager.playButton();
                                              _resume();
                                            },
                                            icon: const Icon(Icons.play_arrow),
                                            label: const Text('Resume'),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.green,
                                              foregroundColor: Colors.white,
                                              padding: EdgeInsets.symmetric(
                                                horizontal: buttonPadding,
                                                vertical: 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                  : Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        ElevatedButton.icon(
                                          onPressed: () => Navigator.pop(context),
                                          icon: const Icon(Icons.home),
                                          label: const Text('Menu'),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.black54,
                                            foregroundColor: Colors.white,
                                            padding: EdgeInsets.symmetric(
                                              horizontal: buttonPadding,
                                              vertical: 12,
                                            ),
                                          ),
                                        ),
                                        SizedBox(width: spacingSmall),
                                        ElevatedButton.icon(
                                          onPressed: () {
                                            soundManager.playButton();
                                            _resume();
                                          },
                                          icon: const Icon(Icons.play_arrow),
                                          label: const Text('Resume'),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.green,
                                            foregroundColor: Colors.white,
                                            padding: EdgeInsets.symmetric(
                                              horizontal: buttonPadding,
                                              vertical: 12,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),

            // Game Over Screen
            if (gameState == GameState.gameOver)
              Container(
                color: Colors.black.withValues(alpha: 0.75),
                child: Center(
                  child: SingleChildScrollView(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final screenWidth = MediaQuery.of(context).size.width;
                        final isSmallScreen = screenWidth < 380;

                        final containerPadding = isSmallScreen ? 16.0 : 24.0;
                        final containerMargin = isSmallScreen ? 12.0 : 20.0;
                        final titleFontSize = isSmallScreen ? 32.0 : 48.0;
                        final finalScoreLabelFontSize = isSmallScreen ? 16.0 : 20.0;
                        final scoreFontSize = isSmallScreen ? 48.0 : 64.0;
                        final mapNameFontSize = isSmallScreen ? 16.0 : 18.0;
                        final mapGravityFontSize = isSmallScreen ? 12.0 : 14.0;
                        final achievementTitleFontSize = isSmallScreen ? 16.0 : 18.0;
                        final achievementItemFontSize = isSmallScreen ? 14.0 : 16.0;
                        final buttonPadding = isSmallScreen ? 16.0 : 24.0;
                        final spacingSmall = isSmallScreen ? 16.0 : 24.0;
                        final spacingMedium = isSmallScreen ? 20.0 : 32.0;

                        return Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Game Over!',
                              style: TextStyle(
                                fontSize: titleFontSize,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(height: spacingMedium),
                            Container(
                              padding: EdgeInsets.all(containerPadding),
                              margin: EdgeInsets.symmetric(horizontal: containerMargin),
                              decoration: BoxDecoration(
                                color: Colors.white12,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    'Final Score',
                                    style: TextStyle(
                                      fontSize: finalScoreLabelFontSize,
                                      color: Colors.white70,
                                    ),
                                  ),
                                  SizedBox(height: isSmallScreen ? 6 : 8),
                                  Text(
                                    '$score',
                                    style: TextStyle(
                                      fontSize: scoreFontSize,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                  SizedBox(height: isSmallScreen ? 12 : 16),
                                  Text(
                                    '${widget.mapData.icon} ${widget.mapData.name}',
                                    style: TextStyle(
                                      fontSize: mapNameFontSize,
                                      color: Colors.white70,
                                    ),
                                  ),
                                  Text(
                                    'Gravity: ${widget.mapData.gravity} m/s²',
                                    style: TextStyle(
                                      fontSize: mapGravityFontSize,
                                      color: Colors.white60,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // Display fun fact
                            if (_currentFunFact != null) ...[
                              SizedBox(height: spacingSmall),
                              Padding(
                                padding: EdgeInsets.symmetric(horizontal: containerMargin),
                                child: PhysicsFunFactWidget(
                                  fact: _currentFunFact!,
                                ),
                              ),
                            ],
                            // Achievement Notifications
                            if (newAchievements.isNotEmpty) ...[
                              SizedBox(height: spacingSmall),
                              Container(
                                padding: EdgeInsets.all(containerPadding),
                                margin: EdgeInsets.symmetric(horizontal: containerMargin),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFFFFD700), // Gold
                                      Color(0xFFFFB6C1), // Pink
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.yellow.withValues(alpha: 0.5),
                                      blurRadius: 20,
                                      offset: const Offset(0, 8),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  children: [
                                    Text(
                                      '🎉 NEW ACHIEVEMENTS! 🎉',
                                      style: TextStyle(
                                        fontSize: achievementTitleFontSize,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                    SizedBox(height: isSmallScreen ? 8 : 12),
                                    ...newAchievements.map((achievement) => Padding(
                                          padding: EdgeInsets.symmetric(
                                            vertical: isSmallScreen ? 2 : 4),
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Text(achievement.icon,
                                                  style: TextStyle(
                                                    fontSize: isSmallScreen ? 20 : 24,
                                                  )),
                                              SizedBox(width: isSmallScreen ? 8 : 10),
                                              Flexible(
                                                child: Text(
                                                  achievement.title,
                                                  style: TextStyle(
                                                    fontSize: achievementItemFontSize,
                                                    fontWeight: FontWeight.bold,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        )),
                                  ],
                                ),
                              ),
                            ],
                            SizedBox(height: spacingMedium),
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: containerMargin),
                              child: isSmallScreen
                                  ? Column(
                                      children: [
                                        SizedBox(
                                          width: double.infinity,
                                          child: ElevatedButton.icon(
                                            onPressed: () {
                                              soundManager.playButton();
                                              _restart();
                                            },
                                            icon: const Icon(Icons.refresh),
                                            label: const Text('Play Again'),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: widget.mapData.primaryColor,
                                              foregroundColor: Colors.white,
                                              padding: EdgeInsets.symmetric(
                                                horizontal: buttonPadding,
                                                vertical: 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                        SizedBox(height: isSmallScreen ? 12 : 16),
                                        SizedBox(
                                          width: double.infinity,
                                          child: ElevatedButton.icon(
                                            onPressed: () {
                                              soundManager.playButton();
                                              Navigator.pop(context);
                                            },
                                            icon: const Icon(Icons.map),
                                            label: const Text('Main menu'),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.white24,
                                              foregroundColor: Colors.white,
                                              padding: EdgeInsets.symmetric(
                                                horizontal: buttonPadding,
                                                vertical: 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                  : Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        ElevatedButton.icon(
                                          onPressed: () {
                                            soundManager.playButton();
                                            _restart();
                                          },
                                          icon: const Icon(Icons.refresh),
                                          label: const Text('Play Again'),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: widget.mapData.primaryColor,
                                            foregroundColor: Colors.white,
                                            padding: EdgeInsets.symmetric(
                                              horizontal: buttonPadding,
                                              vertical: 12,
                                            ),
                                          ),
                                        ),
                                        SizedBox(width: isSmallScreen ? 12 : 16),
                                        ElevatedButton.icon(
                                          onPressed: () {
                                            soundManager.playButton();
                                            Navigator.pop(context);
                                          },
                                          icon: const Icon(Icons.map),
                                          label: const Text('Main menu'),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.white24,
                                            foregroundColor: Colors.white,
                                            padding: EdgeInsets.symmetric(
                                              horizontal: buttonPadding,
                                              vertical: 12,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PhysicsInfo extends StatelessWidget {
  final String label;
  final String value;
  final String unit;

  const _PhysicsInfo({
    required this.label,
    required this.value,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              unit,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
