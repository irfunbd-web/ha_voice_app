// ============================================================================
// File: lib/main.dart
// Description: Custom Voice Assistant for Home Assistant (English & Bangla)
// Dependencies: http, speech_to_text, flutter_tts, shared_preferences, permission_handler
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock orientation to portrait for optimal mobile voice UX
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const HomeAssistantVoiceApp());
}

class HomeAssistantVoiceApp extends StatelessWidget {
  const HomeAssistantVoiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HA Voice Assistant',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F172A), // Slate 900
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8), // Sky 400
          secondary: Color(0xFF818CF8), // Indigo 400
          surface: Color(0xFF1E293B), // Slate 800
          error: Color(0xFFF87171), // Red 400
          onPrimary: Color(0xFF0F172A),
          onSurface: Color(0xFFF8FAFC),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0F172A),
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: Color(0xFFF8FAFC),
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
          iconTheme: IconThemeData(color: Color(0xFFF8FAFC)),
        ),
      ),
      home: const VoiceAssistantHomePage(),
    );
  }
}

class VoiceAssistantHomePage extends StatefulWidget {
  const VoiceAssistantHomePage({super.key});

  @override
  State<VoiceAssistantHomePage> createState() => _VoiceAssistantHomePageState();
}

class _VoiceAssistantHomePageState extends State<VoiceAssistantHomePage>
    with SingleTickerProviderStateMixin {
  // Service instances
  final stt.SpeechToText _speechToText = stt.SpeechToText();
  final FlutterTts _flutterTts = FlutterTts();

  // Animation controller for pulsing microphone FAB
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // Preferences & configuration keys
  static const String _prefKeyBaseUrl = 'ha_base_url';
  static const String _prefKeyToken = 'ha_long_lived_token';
  static const String _prefKeyLocale = 'ha_selected_locale';

  String _baseUrl = 'http://192.168.0.100:8123';
  String _accessToken = '';
  String _selectedLocale = 'en_US'; // 'en_US' or 'bn_BD'

  // Application operational state
  bool _speechEnabled = false;
  bool _isListening = false;
  bool _isProcessing = false;
  bool _isSpeaking = false;

  String _statusText = 'Tap microphone to speak';
  String _recognizedWords = '';
  String _assistantResponse = '';
  String _lastErrorMessage = '';

  // Timer for auto-stopping after silence
  Timer? _silenceTimer;

  @override
  void initState() {
    super.initState();
    _initPulseAnimation();
    _initTextToSpeech();
    _loadPreferences().then((_) {
      _initSpeechRecognition();
    });
  }

  @override
  void dispose() {
    _silenceTimer?.cancel();
    _pulseController.dispose();
    _speechToText.stop();
    _flutterTts.stop();
    super.dispose();
  }

  // --------------------------------------------------------------------------
  // 1. Initializations
  // --------------------------------------------------------------------------

  void _initPulseAnimation() {
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(
        parent: _pulseController,
        curve: Curves.easeInOut,
      ),
    );

    _pulseController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _pulseController.reverse();
      } else if (status == AnimationStatus.dismissed) {
        if (_isListening || _isSpeaking) {
          _pulseController.forward();
        }
      }
    });
  }

  Future<void> _initTextToSpeech() async {
    try {
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setSpeechRate(0.5);
      await _flutterTts.setPitch(1.0);

      _flutterTts.setStartHandler(() {
        if (mounted) {
          setState(() {
            _isSpeaking = true;
            _statusText = 'Speaking...';
          });
          _pulseController.forward();
        }
      });

      _flutterTts.setCompletionHandler(() {
        if (mounted) {
          setState(() {
            _isSpeaking = false;
            _statusText = 'Tap microphone to speak';
          });
          _pulseController.stop();
          _pulseController.reset();
        }
      });

      _flutterTts.setErrorHandler((msg) {
        if (mounted) {
          setState(() {
            _isSpeaking = false;
            _statusText = 'Speech output error';
          });
          _pulseController.stop();
          _pulseController.reset();
        }
      });
    } catch (e) {
      debugPrint('Error initializing TTS: $e');
    }
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _baseUrl =
          prefs.getString(_prefKeyBaseUrl) ?? 'http://192.168.0.100:8123';
      _accessToken = prefs.getString(_prefKeyToken) ?? '';
      _selectedLocale = prefs.getString(_prefKeyLocale) ?? 'en_US';
    });
  }

  Future<void> _savePreferences(String url, String token, String locale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyBaseUrl, url);
    await prefs.setString(_prefKeyToken, token);
    await prefs.setString(_prefKeyLocale, locale);

    setState(() {
      _baseUrl = url;
      _accessToken = token;
      _selectedLocale = locale;
    });
  }

  Future<void> _initSpeechRecognition() async {
    // Request microphone permission via permission_handler
    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      setState(() {
        _statusText = 'Microphone permission denied';
      });
      return;
    }

    try {
      _speechEnabled = await _speechToText.initialize(
        onError: _onSpeechError,
        onStatus: _onSpeechStatus,
        debugLogging: false,
      );
      setState(() {});
    } catch (e) {
      setState(() {
        _speechEnabled = false;
        _statusText = 'Speech engine initialization failed';
      });
    }
  }

  // --------------------------------------------------------------------------
  // 2. Speech-to-Text Handling
  // --------------------------------------------------------------------------

  void _onSpeechStatus(String status) {
    debugPrint('Speech status: $status');
    if (status == 'notListening' && _isListening) {
      _stopListeningAndProcess();
    }
  }

  void _onSpeechError(SpeechRecognitionError error) {
    debugPrint('Speech error: ${error.errorMsg}');
    if (!mounted) return;
    setState(() {
      _isListening = false;
      _statusText = 'Speech error: ${error.errorMsg}';
    });
    _pulseController.stop();
    _pulseController.reset();
  }

  Future<void> _toggleListening() async {
    if (_isProcessing || _isSpeaking) {
      await _flutterTts.stop();
      setState(() {
        _isSpeaking = false;
        _statusText = 'Tap microphone to speak';
      });
      _pulseController.stop();
      _pulseController.reset();
      return;
    }

    if (_isListening) {
      await _stopListeningAndProcess();
    } else {
      await _startListening();
    }
  }

  Future<void> _startListening() async {
    if (!_speechEnabled) {
      final initOk = await _speechToText.initialize(
        onError: _onSpeechError,
        onStatus: _onSpeechStatus,
      );
      if (!initOk) {
        _showSnackBar('Speech recognition is not available on this device.');
        return;
      }
      _speechEnabled = true;
    }

    // Check token before listening
    if (_accessToken.trim().isEmpty) {
      _showSettingsDialog(
        notice:
            'Please enter your Home Assistant Long-Lived Access Token first.',
      );
      return;
    }

    setState(() {
      _isListening = true;
      _statusText = 'Listening...';
      _recognizedWords = '';
      _assistantResponse = '';
      _lastErrorMessage = '';
    });

    _pulseController.forward();

    try {
      await _speechToText.listen(
        onResult: _onSpeechResult,
        localeId: _selectedLocale, // 'en_US' or 'bn_BD'
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        cancelOnError: true,
        listenMode: stt.ListenMode.confirmation,
      );
    } catch (e) {
      setState(() {
        _isListening = false;
        _statusText = 'Could not start listening';
      });
      _pulseController.stop();
      _pulseController.reset();
    }
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    setState(() {
      _recognizedWords = result.recognizedWords;
    });

    // Reset silence timer on fresh words
    _silenceTimer?.cancel();

    if (result.finalResult) {
      _stopListeningAndProcess();
    } else {
      // If user pauses for 2 seconds after speaking something, trigger processing
      _silenceTimer = Timer(const Duration(milliseconds: 2200), () {
        if (_isListening && _recognizedWords.trim().isNotEmpty) {
          _stopListeningAndProcess();
        }
      });
    }
  }

  Future<void> _stopListeningAndProcess() async {
    _silenceTimer?.cancel();
    if (_speechToText.isListening) {
      await _speechToText.stop();
    }

    if (!mounted) return;
    setState(() {
      _isListening = false;
    });

    _pulseController.stop();
    _pulseController.reset();

    final query = _recognizedWords.trim();
    if (query.isNotEmpty) {
      await _sendToHomeAssistant(query);
    } else {
      setState(() {
        _statusText = 'No speech detected. Tap to try again.';
      });
    }
  }

  // --------------------------------------------------------------------------
  // 3. Home Assistant Conversation API Integration
  // --------------------------------------------------------------------------

  Future<void> _sendToHomeAssistant(String commandText) async {
    if (_accessToken.trim().isEmpty) {
      _showSettingsDialog(
        notice: 'Home Assistant Access Token is missing.',
      );
      return;
    }

    setState(() {
      _isProcessing = true;
      _statusText = 'Processing...';
      _lastErrorMessage = '';
    });

    // Format target endpoint: <BASE_URL>/api/services/conversation/process
    String cleanBaseUrl = _baseUrl.trim();
    if (cleanBaseUrl.endsWith('/')) {
      cleanBaseUrl = cleanBaseUrl.substring(0, cleanBaseUrl.length - 1);
    }
    final Uri targetUri =
        Uri.parse('$cleanBaseUrl/api/services/conversation/process');

    final Map<String, String> headers = {
      'Authorization': 'Bearer ${_accessToken.trim()}',
      'Content-Type': 'application/json',
    };

    final Map<String, dynamic> body = {
      'text': commandText,
      // Map flutter locale to Home Assistant conversation language code
      'language': _selectedLocale.startsWith('bn') ? 'bn' : 'en',
    };

    try {
      final response = await http
          .post(
            targetUri,
            headers: headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseData = jsonDecode(response.body);

        // Home Assistant Conversation service response JSON hierarchy:
        // response -> speech -> plain -> speech
        String? replyText;

        if (responseData.containsKey('response') &&
            responseData['response'] is Map<String, dynamic>) {
          final respMap = responseData['response'] as Map<String, dynamic>;
          if (respMap.containsKey('speech') &&
              respMap['speech'] is Map<String, dynamic>) {
            final speechMap = respMap['speech'] as Map<String, dynamic>;
            if (speechMap.containsKey('plain') &&
                speechMap['plain'] is Map<String, dynamic>) {
              replyText = speechMap['plain']['speech']?.toString();
            }
          }
        }

        // Fallback checks for custom conversation integrations
        replyText ??= responseData['speech']?.toString() ??
            responseData['message']?.toString() ??
            'Command executed successfully.';

        setState(() {
          _isProcessing = false;
          _assistantResponse = replyText!;
          _statusText = 'Speaking...';
        });

        await _speakResponse(replyText);
      } else if (response.statusCode == 401) {
        throw Exception(
            'Unauthorized (401): Please verify your Long-Lived Access Token.');
      } else if (response.statusCode == 404) {
        throw Exception(
            'Endpoint not found (404): Ensure the "conversation" integration is loaded in Home Assistant.');
      } else {
        throw Exception(
            'Server error (${response.statusCode}): ${response.body}');
      }
    } on TimeoutException {
      _handleError(
          'Connection timeout. Please verify Home Assistant server IP and port.');
    } catch (e) {
      _handleError(e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted && _isProcessing) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  void _handleError(String message) {
    if (!mounted) return;
    setState(() {
      _isProcessing = false;
      _lastErrorMessage = message;
      _statusText = 'Error occurred';
    });
    _showSnackBar(message, isError: true);
  }

  // --------------------------------------------------------------------------
  // 4. Text-to-Speech Output
  // --------------------------------------------------------------------------

  Future<void> _speakResponse(String text) async {
    try {
      // Set speech language matching the selected locale
      if (_selectedLocale.startsWith('bn')) {
        await _flutterTts.setLanguage('bn-BD');
      } else {
        await _flutterTts.setLanguage('en-US');
      }
      await _flutterTts.speak(text);
    } catch (e) {
      debugPrint('TTS speak failure: $e');
      if (mounted) {
        setState(() {
          _isSpeaking = false;
          _statusText = 'Tap microphone to speak';
        });
      }
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontSize: 14, color: Colors.white),
        ),
        backgroundColor:
            isError ? const Color(0xFFEF4444) : const Color(0xFF0284C7),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // 5. Settings Modal / Dialog
  // --------------------------------------------------------------------------

  void _showSettingsDialog({String? notice}) {
    final urlController = TextEditingController(text: _baseUrl);
    final tokenController = TextEditingController(text: _accessToken);
    String tempLocale = _selectedLocale;
    bool obscureToken = true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                top: 24,
                left: 20,
                right: 20,
              ),
              decoration: const BoxDecoration(
                color: Color(0xFF1E293B), // Slate 800
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black54,
                    blurRadius: 20,
                    offset: Offset(0, -4),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Sheet grab bar
                    Center(
                      child: Container(
                        width: 44,
                        height: 5,
                        decoration: BoxDecoration(
                          color: const Color(0xFF475569),
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),

                    // Header title
                    const Row(
                      children: [
                        Icon(Icons.tune_rounded,
                            color: Color(0xFF38BDF8), size: 24),
                        SizedBox(width: 10),
                        Text(
                          'Configuration',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFF8FAFC),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Configure your Home Assistant server URL and token.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                    ),
                    if (notice != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0x33EF4444),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFEF4444)),
                        ),
                        child: Text(
                          notice,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFFCA5A5),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),

                    // Server Base URL field
                    const Text(
                      'Home Assistant Server Base URL',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFE2E8F0),
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: urlController,
                      keyboardType: TextInputType.url,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'http://192.168.0.100:8123',
                        hintStyle: const TextStyle(color: Color(0xFF64748B)),
                        filled: true,
                        fillColor: const Color(0xFF0F172A),
                        prefixIcon: const Icon(Icons.dns_rounded,
                            color: Color(0xFF38BDF8), size: 20),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 14),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Long-Lived Access Token field
                    const Text(
                      'Long-Lived Access Token',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFE2E8F0),
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: tokenController,
                      obscureText: obscureToken,
                      maxLines: 1,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...',
                        hintStyle: const TextStyle(color: Color(0xFF64748B)),
                        filled: true,
                        fillColor: const Color(0xFF0F172A),
                        prefixIcon: const Icon(Icons.key_rounded,
                            color: Color(0xFF38BDF8), size: 20),
                        suffixIcon: IconButton(
                          icon: Icon(
                            obscureToken
                                ? Icons.visibility_off
                                : Icons.visibility,
                            color: const Color(0xFF94A3B8),
                            size: 20,
                          ),
                          onPressed: () {
                            setModalState(() {
                              obscureToken = !obscureToken;
                            });
                          },
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 14),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Language selection
                    const Text(
                      'Speech Recognition Language',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFE2E8F0),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              setModalState(() {
                                tempLocale = 'en_US';
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: tempLocale == 'en_US'
                                    ? const Color(0xFF38BDF8)
                                        .withValues(alpha: 0.15)
                                    : const Color(0xFF0F172A),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: tempLocale == 'en_US'
                                      ? const Color(0xFF38BDF8)
                                      : const Color(0xFF334155),
                                  width: 1.5,
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.language_rounded,
                                    size: 18,
                                    color: tempLocale == 'en_US'
                                        ? const Color(0xFF38BDF8)
                                        : const Color(0xFF94A3B8),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'English (en_US)',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                      color: tempLocale == 'en_US'
                                          ? const Color(0xFF38BDF8)
                                          : const Color(0xFFCBD5E1),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              setModalState(() {
                                tempLocale = 'bn_BD';
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: tempLocale == 'bn_BD'
                                    ? const Color(0xFF38BDF8)
                                        .withValues(alpha: 0.15)
                                    : const Color(0xFF0F172A),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: tempLocale == 'bn_BD'
                                      ? const Color(0xFF38BDF8)
                                      : const Color(0xFF334155),
                                  width: 1.5,
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.translate_rounded,
                                    size: 18,
                                    color: tempLocale == 'bn_BD'
                                        ? const Color(0xFF38BDF8)
                                        : const Color(0xFF94A3B8),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'বাংলা (bn_BD)',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                      color: tempLocale == 'bn_BD'
                                          ? const Color(0xFF38BDF8)
                                          : const Color(0xFFCBD5E1),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Action buttons (Test & Save)
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.bolt_rounded, size: 18),
                            label: const Text('Test Ping'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF94A3B8),
                              side: const BorderSide(color: Color(0xFF475569)),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: () async {
                              final testUrl = urlController.text.trim();
                              final testToken = tokenController.text.trim();
                              if (testUrl.isEmpty || testToken.isEmpty) {
                                _showSnackBar(
                                    'Please provide both URL and Token to test.',
                                    isError: true);
                                return;
                              }
                              _showSnackBar(
                                  'Testing connection to Home Assistant...');
                              try {
                                String clean = testUrl.endsWith('/')
                                    ? testUrl.substring(0, testUrl.length - 1)
                                    : testUrl;
                                final res = await http.get(
                                  Uri.parse('$clean/api/'),
                                  headers: {
                                    'Authorization': 'Bearer $testToken'
                                  },
                                ).timeout(const Duration(seconds: 8));
                                if (res.statusCode == 200) {
                                  _showSnackBar(
                                      'Connection successful! Home Assistant is online.');
                                } else {
                                  _showSnackBar(
                                      'Response: ${res.statusCode} ${res.reasonPhrase}',
                                      isError: true);
                                }
                              } catch (e) {
                                _showSnackBar('Connection failed: $e',
                                    isError: true);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.save_rounded, size: 18),
                            label: const Text('Save Settings'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF38BDF8),
                              foregroundColor: const Color(0xFF0F172A),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: () {
                              _savePreferences(
                                urlController.text.trim(),
                                tokenController.text.trim(),
                                tempLocale,
                              );
                              Navigator.pop(context);
                              _showSnackBar('Settings saved successfully.');
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // --------------------------------------------------------------------------
  // 6. UI Build
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.home_outlined, size: 22, color: Color(0xFF38BDF8)),
            SizedBox(width: 8),
            Text('Home Assistant Voice'),
          ],
        ),
        actions: [
          // Language quick switch badge button
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Material(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  final nextLocale =
                      _selectedLocale == 'en_US' ? 'bn_BD' : 'en_US';
                  _savePreferences(_baseUrl, _accessToken, nextLocale);
                  _showSnackBar(
                    nextLocale == 'bn_BD'
                        ? 'Language: বাংলা (bn_BD)'
                        : 'Language: English (en_US)',
                  );
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.language,
                          size: 14, color: Color(0xFF38BDF8)),
                      const SizedBox(width: 4),
                      Text(
                        _selectedLocale == 'bn_BD' ? 'বাংলা' : 'EN',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFF8FAFC),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => _showSettingsDialog(),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0),
          child: Column(
            children: [
              const SizedBox(height: 12),

              // Status indicator banner
              _buildStatusIndicator(),

              const SizedBox(height: 20),

              // Transcript & Response Card Area (Scrollable if text is long)
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Recognized user voice text card
                      _buildDisplayCard(
                        title: 'You Said',
                        subtitle: _selectedLocale == 'bn_BD'
                            ? 'Bangla Voice Input'
                            : 'English Voice Input',
                        icon: Icons.record_voice_over_rounded,
                        accentColor: const Color(0xFF38BDF8),
                        content: _recognizedWords.isEmpty
                            ? (_isListening
                                ? 'Listening for speech...'
                                : 'Press the mic below to issue a command.')
                            : _recognizedWords,
                        isPlaceholder: _recognizedWords.isEmpty,
                      ),

                      const SizedBox(height: 16),

                      // Home Assistant response card
                      _buildDisplayCard(
                        title: 'Home Assistant',
                        subtitle: 'Conversation Process Response',
                        icon: Icons.smart_toy_outlined,
                        accentColor: const Color(0xFF818CF8),
                        content: _assistantResponse.isEmpty
                            ? (_isProcessing
                                ? 'Waiting for Home Assistant response...'
                                : 'Responses from Home Assistant will appear here.')
                            : _assistantResponse,
                        isPlaceholder: _assistantResponse.isEmpty,
                        trailing: _assistantResponse.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.volume_up_rounded,
                                    size: 20),
                                color: const Color(0xFF38BDF8),
                                tooltip: 'Replay audio',
                                onPressed: () =>
                                    _speakResponse(_assistantResponse),
                              )
                            : null,
                      ),

                      if (_lastErrorMessage.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0x22EF4444),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0x66EF4444)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline_rounded,
                                  color: Color(0xFFF87171), size: 20),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _lastErrorMessage,
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFFFCA5A5)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Central Large Animated Microphone FAB Section
              _buildMicrophoneSection(),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // 7. Component Widgets
  // --------------------------------------------------------------------------

  Widget _buildStatusIndicator() {
    Color badgeColor;
    Color textColor;
    IconData statusIcon;

    if (_isListening) {
      badgeColor = const Color(0xFFEF4444); // Red pulse
      textColor = const Color(0xFFFCA5A5);
      statusIcon = Icons.mic_rounded;
    } else if (_isProcessing) {
      badgeColor = const Color(0xFFEAB308); // Amber processing
      textColor = const Color(0xFFFDE047);
      statusIcon = Icons.sync_rounded;
    } else if (_isSpeaking) {
      badgeColor = const Color(0xFF38BDF8); // Sky speaking
      textColor = const Color(0xFFBAE6FD);
      statusIcon = Icons.graphic_eq_rounded;
    } else {
      badgeColor = const Color(0xFF475569); // Slate idle
      textColor = const Color(0xFF94A3B8);
      statusIcon = Icons.touch_app_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: badgeColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: badgeColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Icon(statusIcon, size: 16, color: textColor),
          const SizedBox(width: 6),
          Text(
            _statusText,
            style: TextStyle(
              color: textColor,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDisplayCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color accentColor,
    required String content,
    required bool isPlaceholder,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B), // Slate 800
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF334155), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: accentColor, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFF8FAFC),
                      ),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 14),
          Text(
            content,
            style: TextStyle(
              fontSize: 15,
              height: 1.45,
              color: isPlaceholder
                  ? const Color(0xFF64748B)
                  : const Color(0xFFE2E8F0),
              fontStyle: isPlaceholder ? FontStyle.italic : FontStyle.normal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMicrophoneSection() {
    return Column(
      children: [
        // Ripple & pulsing mic button container
        GestureDetector(
          onTap: _toggleListening,
          child: AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              final double scale =
                  (_isListening || _isSpeaking) ? _pulseAnimation.value : 1.0;
              final Color glowColor = _isListening
                  ? const Color(0xFFEF4444)
                  : (_isSpeaking
                      ? const Color(0xFF818CF8)
                      : const Color(0xFF38BDF8));

              return Stack(
                alignment: Alignment.center,
                children: [
                  // Outer soft glowing aura ring
                  if (_isListening || _isSpeaking)
                    Container(
                      width: 120 * scale,
                      height: 120 * scale,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: glowColor.withValues(alpha: 0.15),
                      ),
                    ),
                  // Middle pulse ring
                  if (_isListening || _isSpeaking)
                    Container(
                      width: 100 * scale,
                      height: 100 * scale,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: glowColor.withValues(alpha: 0.25),
                      ),
                    ),
                  // Main Core Action Button
                  Container(
                    width: 78,
                    height: 78,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: _isListening
                            ? [const Color(0xFFEF4444), const Color(0xFFDC2626)]
                            : (_isSpeaking
                                ? [
                                    const Color(0xFF818CF8),
                                    const Color(0xFF6366F1)
                                  ]
                                : [
                                    const Color(0xFF38BDF8),
                                    const Color(0xFF0284C7)
                                  ]),
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: glowColor.withValues(alpha: 0.4),
                          blurRadius: 20,
                          spreadRadius: 2,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Icon(
                        _isListening
                            ? Icons.stop_rounded
                            : (_isProcessing
                                ? Icons.hourglass_top_rounded
                                : (_isSpeaking
                                    ? Icons.volume_up_rounded
                                    : Icons.mic_rounded)),
                        color: Colors.white,
                        size: 36,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        Text(
          _isListening
              ? 'Tap to send immediately'
              : (_isProcessing
                  ? 'Querying Home Assistant...'
                  : (_isSpeaking
                      ? 'Tap to silence'
                      : 'Tap to start voice command')),
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFF94A3B8),
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
