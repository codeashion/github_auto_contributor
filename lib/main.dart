import 'dart:convert';
import 'package:auto_git_pusher/rawCommitData.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GitHub Auto Contributor',
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: const Color(0xFF24292E),
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        cardColor: const Color(0xFF161B22),
        colorScheme: const ColorScheme.dark(
          primary: Colors.green,
          secondary: Colors.blueAccent,
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Colors.white),
          bodyMedium: TextStyle(color: Colors.white70),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Colors.white24),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Colors.green),
          ),
          labelStyle: const TextStyle(color: Colors.white70),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      ),
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Controllers for the input fields
  final _tokenController = TextEditingController();
  final _repoController = TextEditingController();

  // Secure storage for the GitHub token
  final _storage = const FlutterSecureStorage();

  // State variables
  bool _isLoading = true;
  bool _credentialsExist = false;
  String _statusMessage = "Initializing...";
  String _savedRepo = "";

  @override
  void initState() {
    super.initState();
    _loadDataAndAttemptContribution();
  }

  /// Loads credentials from storage and triggers the contribution logic if they exist.
  Future<void> _loadDataAndAttemptContribution() async {
    setState(() {
      _isLoading = true;
      _statusMessage = "Checking for saved credentials...";
    });

    final token = await _storage.read(key: 'github_token');
    final prefs = await SharedPreferences.getInstance();
    final repo = prefs.getString('github_repo');

    if (token != null && repo != null && token.isNotEmpty && repo.isNotEmpty) {
      setState(() {
        _credentialsExist = true;
        _savedRepo = repo;
        _statusMessage = "Credentials found. Preparing to contribute...";
      });
      await _makeContribution();
    } else {
      setState(() {
        _credentialsExist = false;
        _statusMessage = "Please set up your GitHub credentials.";
      });
    }
    setState(() {
      _isLoading = false;
    });
  }

  /// Saves the user's GitHub token and repository path.
  Future<void> _saveCredentials() async {
    if (_tokenController.text.isEmpty || _repoController.text.isEmpty) {
      _showSnackBar("Token and Repository cannot be empty.", isError: true);
      return;
    }

    // Basic validation for repo format owner/repo
    if (!_repoController.text.contains('/')) {
      _showSnackBar(
        "Invalid repository format. Use 'owner/repo'.",
        isError: true,
      );
      return;
    }

    setState(() => _isLoading = true);
    await _storage.write(key: 'github_token', value: _tokenController.text);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('github_repo', _repoController.text);

    _tokenController.clear();
    _repoController.clear();

    _showSnackBar("Credentials saved successfully!", isError: false);
    await _loadDataAndAttemptContribution();
  }

  /// Clears the saved credentials from storage.
  Future<void> _clearCredentials() async {
    setState(() => _isLoading = true);
    await _storage.delete(key: 'github_token');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('github_repo');
    setState(() {
      _credentialsExist = false;
      _isLoading = false;
      _statusMessage = "Credentials cleared. Please set up to continue.";
    });
  }

  /// Core logic to make a commit to the specified repository.
  Future<void> _makeContribution() async {
    setState(() {
      _statusMessage = "Starting contribution process for '$_savedRepo'...";
    });
    try {
      final token = await _storage.read(key: 'github_token');
      if (token == null || token.isEmpty) {
        setState(() {
          _statusMessage =
              "GitHub token missing. Please set up your credentials.";
        });
        return;
      }
      final repo = _savedRepo;
      if (repo.isEmpty) {
        setState(() {
          _statusMessage =
              "Repository missing. Please set up your credentials.";
        });
        return;
      }
      final headers = {
        'Authorization': 'token $token',
        'Accept': 'application/vnd.github.v3+json',
      };
      const filePath = 'contribution_log.txt';
      final commitMessage = getRandomCommitMessage();

      // 1. Get default branch
      final repoInfoUrl = Uri.parse('https://api.github.com/repos/$repo');
      final repoInfoRes = await http.get(repoInfoUrl, headers: headers);
      if (repoInfoRes.statusCode != 200) {
        final errorBody = jsonDecode(repoInfoRes.body);
        setState(() {
          _statusMessage =
              'Failed to fetch repo info: ${errorBody['message'] ?? repoInfoRes.body}';
        });
        return;
      }
      final defaultBranch = jsonDecode(repoInfoRes.body)['default_branch'];
      setState(() => _statusMessage = "Found default branch: $defaultBranch");

      // 2. Get the content of the file to update it (if it exists)
      final fileUrl = Uri.parse(
        'https://api.github.com/repos/$repo/contents/$filePath',
      );
      final fileRes = await http.get(fileUrl, headers: headers);
      String currentContent = "";
      String? fileSha;
      if (fileRes.statusCode == 200) {
        final fileData = jsonDecode(fileRes.body);
        currentContent = utf8.decode(
          base64.decode(fileData['content'].replaceAll('\n', '')),
        );
        fileSha = fileData['sha'];
      } else if (fileRes.statusCode != 404) {
        final errorBody = jsonDecode(fileRes.body);
        setState(() {
          _statusMessage =
              'Error fetching file content: ${errorBody['message'] ?? fileRes.body}';
        });
        return;
      }

      // 3. Create the new content
      final newContent =
          '${currentContent}\nContribution made on ${DateTime.now().toIso8601String()}'
              .trim();
      final newContentBase64 = base64.encode(utf8.encode(newContent));

      // 4. Update the file (or create it)
      final updateUrl = Uri.parse(
        'https://api.github.com/repos/$repo/contents/$filePath',
      );
      final updateBody = {
        'message': commitMessage,
        'content': newContentBase64,
        'branch': defaultBranch,
        if (fileSha != null)
          'sha': fileSha, // Include SHA if updating an existing file
      };
      final updateRes = await http.put(
        updateUrl,
        headers: headers,
        body: jsonEncode(updateBody),
      );

      if (updateRes.statusCode == 200 || updateRes.statusCode == 201) {
        final commitSha = jsonDecode(updateRes.body)['commit']['sha'];
        setState(
          () =>
              _statusMessage =
                  'Successfully committed!\nCommit SHA: ${commitSha.substring(0, 7)}',
        );
      } else {
        setState(() {
          _statusMessage =
              'Failed to create or update file: ${jsonDecode(updateRes.body)['message'] ?? updateRes.body}\n'
              'Repo: $repo\n'
              'Branch: $defaultBranch\n'
              'File: $filePath\n'
              'Status: ${updateRes.statusCode}\n'
              'Response: ${updateRes.body}';
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Error making contribution:\n$e';
      });
    }
  }

  void _showSnackBar(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.redAccent : Colors.green,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GitHub Auto Contributor'),
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child:
              _isLoading
                  ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 20),
                      Text(
                        _statusMessage,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ],
                  )
                  : _credentialsExist
                  ? _buildStatusView()
                  : _buildSetupView(),
        ),
      ),
    );
  }

  /// Builds the UI for setting up credentials.
  Widget _buildSetupView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.settings, size: 60, color: Colors.white70),
        const SizedBox(height: 20),
        Text(
          'Setup Your Account',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        const Text(
          'This app requires a GitHub Personal Access Token with `repo` scope to make commits.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 30),
        TextField(
          controller: _tokenController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'GitHub Personal Access Token',
            prefixIcon: Icon(Icons.vpn_key),
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _repoController,
          decoration: const InputDecoration(
            labelText: 'Repository (e.g., owner/repo_name)',
            prefixIcon: Icon(Icons.book),
          ),
        ),
        const SizedBox(height: 30),
        ElevatedButton(
          onPressed: _saveCredentials,
          child: const Text('Save and Contribute'),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: () {
            launchUrl(
              Uri.parse('https://github.com/settings/tokens/new?scopes=repo'),
            );
          },
          child: const Text('How to get a Token?'),
        ),
      ],
    );
  }

  /// Builds the UI for displaying the contribution status.
  Widget _buildStatusView() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 5,
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.cloud_done, size: 60, color: Colors.green),
            const SizedBox(height: 20),
            Text(
              'Contribution Status',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Text(
              'Repository: $_savedRepo',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _statusMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: 'monospace', height: 1.5),
              ),
            ),
            const SizedBox(height: 30),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
              ),
              onPressed: _makeContribution,
              child: const Text('Run Contribution Manually'),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _clearCredentials,
              child: const Text(
                'Clear Settings',
                style: TextStyle(color: Colors.amber),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _repoController.dispose();
    super.dispose();
  }
}
