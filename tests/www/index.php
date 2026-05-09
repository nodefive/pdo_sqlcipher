<?php
// Start output buffering
ob_start();

// Enable error reporting for debugging
error_reporting(E_ALL);
ini_set('display_errors', 1);

// Custom shutdown function to catch fatal errors
function shutdownHandler() {
    $error = error_get_last();
    if ($error !== null && ($error['type'] === E_ERROR || $error['type'] === E_PARSE || $error['type'] === E_CORE_ERROR || $error['type'] === E_COMPILE_ERROR)) {
        error_log("Fatal Error: {$error['message']} in {$error['file']} on line {$error['line']}");
        header("Location: /");
        exit();
    }
}
register_shutdown_function("shutdownHandler");

// --- Sync Logic ---

function calculate_sha256($file_path) {
    return hash_file('sha256', $file_path);
}

function get_remote_hash($sftp, $remote_path_prefix, $file) {
    $hash_file = $remote_path_prefix . $file . '.sha256';
    $remote_base_hash = 'ssh2.sftp://' . intval($sftp) . '/' . $hash_file;
    if (file_exists($remote_base_hash)) {
        $content = file_get_contents($remote_base_hash);
        return trim(explode(' ', $content)[0]);
    }
    return null;
}

function upload_with_hash($local_file, $sftp, $remote_path_prefix, $file) {
    $remote_file_path = 'ssh2.sftp://' . intval($sftp) . '/' . $remote_path_prefix . $file;
    if (copy($local_file, $remote_file_path)) {
        $hash = calculate_sha256($local_file);
        $hash_content = "$hash  $file";
        $hash_remote_path = $remote_file_path . '.sha256';
        file_put_contents($hash_remote_path, $hash_content);
        
        // Match mtime of sidecar to db file if possible, or just ensure db file mtime is set
        $mtime = filemtime($local_file);
        // We can't easily set mtime on remote via ssh2.sftp wrapper for copy, 
        // but we can try to use touch on the sftp stream if supported or just rely on local touch after pull.
        return true;
    }
    return false;
}

function sync_databases($settings) {
    $server = $settings['server'];
    $port = isset($settings['port']) ? $settings['port'] : 22;
    $user = $settings['user'];
    $password = $settings['password'];
    $remote_dir = $settings['remote_dir'];
    $local_dir = '/var/www/html/';

    $output = '';
    $total_synced = 0;
    $total_up_to_date = 0;

    $connection = ssh2_connect($server, $port);
    if (!$connection) return "Connection failed";
    if (!ssh2_auth_password($connection, $user, $password)) return "Authentication failed";
    $sftp = ssh2_sftp($connection);
    if (!$sftp) return "SFTP session failed";

    $remote_path_prefix = ltrim($remote_dir, './');
    if (!empty($remote_path_prefix) && substr($remote_path_prefix, -1) !== '/') $remote_path_prefix .= '/';
    $remote_base = 'ssh2.sftp://' . intval($sftp) . '/' . $remote_path_prefix;

    $remote_files = [];
    $handle = opendir($remote_base);
    if ($handle) {
        while (false !== ($file = readdir($handle))) {
            if (substr($file, -3) === '.db') {
                $remote_stat = ssh2_sftp_stat($sftp, $remote_path_prefix . $file);
                $remote_files[$file] = [
                    'mtime' => $remote_stat['mtime'],
                    'hash' => get_remote_hash($sftp, $remote_path_prefix, $file)
                ];
            }
        }
        closedir($handle);
    }

    $local_files = [];
    if (is_dir($local_dir)) {
        $handle = opendir($local_dir);
        while (false !== ($file = readdir($handle))) {
            if (substr($file, -3) === '.db') {
                $local_files[$file] = [
                    'mtime' => filemtime("$local_dir/$file"),
                    'hash' => calculate_sha256("$local_dir/$file")
                ];
            }
        }
        closedir($handle);
    }

    $all_files = array_keys($remote_files + $local_files);
    sort($all_files);

    $icon_synced = '<svg class="sync-icon synced" viewBox="0 0 24 24"><path fill="currentColor" d="M9,16.17L4.83,12l-1.42,1.41L9,19 21,7l-1.41,-1.41z"/></svg>';
    $icon_push = '<svg class="sync-icon push" viewBox="0 0 24 24"><path fill="currentColor" d="M12,4l-8,8h5v8h6v-8h5z"/></svg>';
    $icon_pull = '<svg class="sync-icon pull" viewBox="0 0 24 24"><path fill="currentColor" d="M12,20l8,-8h-5v-8h-6v8h-5z"/></svg>';

    foreach ($all_files as $file) {
        $local_exists = isset($local_files[$file]);
        $remote_exists = isset($remote_files[$file]);
        $status_html = '';

        if ($local_exists && $remote_exists) {
            $local_hash = $local_files[$file]['hash'];
            $remote_hash = $remote_files[$file]['hash'];

            if ($remote_hash !== null && $local_hash === $remote_hash) {
                $status_html = $icon_synced;
                $total_up_to_date++;
            } else {
                $local_mtime = $local_files[$file]['mtime'];
                $remote_mtime = $remote_files[$file]['mtime'];

                if (abs($local_mtime - $remote_mtime) <= 2) {
                    $status_html = $icon_synced;
                    $total_up_to_date++;
                } elseif ($local_mtime > $remote_mtime) {
                    if (upload_with_hash("$local_dir/$file", $sftp, $remote_path_prefix, $file)) {
                        $status_html = $icon_push;
                        $total_synced++;
                    }
                } else {
                    if (copy($remote_base . $file, "$local_dir/$file")) {
                        touch("$local_dir/$file", $remote_mtime);
                        $status_html = $icon_pull;
                        $total_synced++;
                    }
                }
            }
        } elseif ($local_exists) {
            if (upload_with_hash("$local_dir/$file", $sftp, $remote_path_prefix, $file)) {
                $status_html = $icon_push;
                $total_synced++;
            }
        } elseif ($remote_exists) {
            if (copy($remote_base . $file, "$local_dir/$file")) {
                touch("$local_dir/$file", $remote_files[$file]['mtime']);
                $status_html = $icon_pull;
                $total_synced++;
            }
        }

        if ($status_html) {
            $output .= "<div class='sync-item'><span class='db-name'>$file</span>$status_html</div>";
        }
    }

    $total_count = count($all_files);
    $output .= "<div class='sync-summary'>Total: $total_count | Synced: $total_synced | Up-to-date: $total_up_to_date</div>";

    return $output;
}


// --- Configuration Storage ---

function getSyncSettingsPath() {
    // Store in a secure, non-web-accessible location
    return '/var/www/sync/guardian.json';
}

function getSyncSettings() {
    $path = getSyncSettingsPath();
    if (!file_exists($path)) {
        // Default settings
        return [
            'server' => '',
            'port' => '22',
            'user' => '',
            'remote_dir' => '',
            'password' => ''
        ];
    }
    $json = file_get_contents($path);
    $settings = json_decode($json, true);
    
    // Decrypt sensitive values
    if (isset($settings['server'])) $settings['server'] = decryptValue($settings['server']);
    if (isset($settings['port'])) $settings['port'] = decryptValue($settings['port']);
    if (isset($settings['user'])) $settings['user'] = decryptValue($settings['user']);
    if (isset($settings['remote_dir'])) $settings['remote_dir'] = decryptValue($settings['remote_dir']);
    if (isset($settings['password'])) $settings['password'] = decryptValue($settings['password']);

    // Ensure port has a default if missing after decryption
    if (!isset($settings['port']) || empty($settings['port'])) $settings['port'] = '22';

    return $settings;
}

function saveSyncSettings($server, $port, $user, $remote_dir, $password) {
    $path = getSyncSettingsPath();
    if (!is_dir(dirname($path))) {
        // Create directory with restrictive permissions (e.g., 0700)
        mkdir(dirname($path), 0700, true);
    }
    file_put_contents($path, json_encode([
        'server' => encryptValue($server),
        'port' => encryptValue($port),
        'user' => encryptValue($user),
        'remote_dir' => encryptValue($remote_dir),
        'password' => encryptValue($password)
    ], JSON_PRETTY_PRINT));
    // Set restrictive permissions on the file itself (e.g., 0600)
    chmod($path, 0600);
}

// --- Encryption ---
// IMPORTANT: Replace this with a more secure key management system
define('ENCRYPTION_KEY_PATH', '/var/www/sync/encryption.key');

function getEncryptionKey() {
    if (!file_exists(ENCRYPTION_KEY_PATH)) {
        if (!is_dir(dirname(ENCRYPTION_KEY_PATH))) {
            // Create directory with restrictive permissions (e.g., 0700)
            mkdir(dirname(ENCRYPTION_KEY_PATH), 0700, true);
        }
        // Generate a new key if it doesn't exist
        $key = random_bytes(32); // 256-bit key
        file_put_contents(ENCRYPTION_KEY_PATH, $key);
        // Set restrictive permissions on the file itself (e.g., 0600)
        chmod(ENCRYPTION_KEY_PATH, 0600);
        return $key;
    }
    return file_get_contents(ENCRYPTION_KEY_PATH);
}

function encryptValue($value) {
    if (empty($value)) return '';
    $key = getEncryptionKey();
    $iv = random_bytes(16); // AES-256-CBC requires a 16-byte IV
    $encrypted = openssl_encrypt($value, 'aes-256-cbc', $key, 0, $iv);
    return base64_encode($iv . $encrypted);
}

function decryptValue($value) {
    if (empty($value)) return '';
    $key = getEncryptionKey();
    $decoded = base64_decode($value);
    $iv = substr($decoded, 0, 16);
    $encrypted = substr($decoded, 16);
    return openssl_decrypt($encrypted, 'aes-256-cbc', $key, 0, $iv);
}

// --- Configuration & Helpers ---

$dbsPath = '/var/www/html/';
$availableDbs = glob($dbsPath . '*.db');
$dbList = [];
if ($availableDbs) {
    foreach ($availableDbs as $dbFile) {
        $dbList[] = basename($dbFile);
    }
}

// Determine Selected DB
$selectedDb = 'db.db'; // Fallback default
if (isset($_POST['selected_db'])) {
    $selectedDb = $_POST['selected_db'];
    // Handle "Set as Default"
    if (isset($_POST['set_default']) && $_POST['set_default'] == '1') {
        setcookie('default_db', $selectedDb, time() + (86400 * 30), "/"); // 30 days
    }
} elseif (isset($_COOKIE['default_db']) && in_array($_COOKIE['default_db'], $dbList)) {
    $selectedDb = $_COOKIE['default_db'];
}

// Current DB Path
$dbPath = $dbsPath . $selectedDb;

// Inputs
$query = isset($_POST['query']) ? $_POST['query'] : '';
$dkey = isset($_POST['dkey']) ? $_POST['dkey'] : '';
$action = isset($_POST['action']) ? $_POST['action'] : '';

$message = '';
$messageType = ''; // 'success' or 'error'

// --- Database Connection ---

function getPdo($dbFile, $key) {
    if (!file_exists($dbFile)) {
        throw new Exception("Database file not found: $dbFile");
    }
    $dsn = "sqlcipher:$dbFile";
    $pdo = new PDO($dsn);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    // Sanitize key for Pragma - basic escaping
    $safeKey = str_replace("'", "''", $key);
    $pdo->exec("PRAGMA key = '$safeKey';");
    return $pdo;
}

// --- Action Handling ---

$results = [];

if ($_SERVER["REQUEST_METHOD"] == "POST") {
    if ($action === 'save_settings') {
        saveSyncSettings($_POST['server'], $_POST['port'], $_POST['user'], $_POST['remote_dir'], $_POST['password']);
        $message = "Settings saved successfully";
        $messageType = "success";
    } elseif ($action === 'sync') {
        $settings = getSyncSettings();
        $output = sync_databases($settings);
        $message = "<div class='sync-output'>$output</div>";
        $messageType = "success";
    }

    if ($dkey && in_array($action, ['add', 'edit', 'delete', ''])) {
        try {
            $pdo = getPdo($dbPath, $dkey);

            // Verify Key
            try {
                $pdo->query("SELECT count(*) FROM sqlite_master");
            } catch (PDOException $e) {
                throw new Exception("Incorrect Key or Corrupt Database.");
            }

            // Handle Actions
            if ($action === 'add') {
                $stmt = $pdo->prepare("INSERT INTO loginfo (account, login, passwd, url, info) VALUES (:account, :login, :passwd, :url, :info)");
                $stmt->execute([
                    ':account' => str_replace(' ', '\\ ', $_POST['account']),
                    ':login' => str_replace(' ', '\\ ', str_replace("\n", "\\", str_replace("\r\n", "\n", $_POST['login']))),
                    ':passwd' => str_replace(' ', '\\ ', str_replace("\n", "\\", str_replace("\r\n", "\n", $_POST['passwd']))),
                    ':url' => str_replace(' ', '\\ ', str_replace("\n", "\\", str_replace("\r\n", "\n", $_POST['url']))),
                    ':info' => str_replace(' ', '\\ ', str_replace("\n", "\\", str_replace("\r\n", "\n", $_POST['info'])))
                ]);
                $message = "Item added successfully";
                $messageType = "success";
            } elseif ($action === 'edit') {
                $stmt = $pdo->prepare("UPDATE loginfo SET account = :account, login = :login, passwd = :passwd, url = :url, info = :info WHERE id = :id");
                $stmt->execute([
                    ':account' => str_replace(' ', '\\ ', $_POST['account']),
                    ':login' => str_replace(' ', '\\ ', str_replace("\n", "\\", str_replace("\r\n", "\n", $_POST['login']))),
                    ':passwd' => str_replace(' ', '\\ ', str_replace("\n", "\\", str_replace("\r\n", "\n", $_POST['passwd']))),
                    ':url' => str_replace(' ', '\\ ', str_replace("\n", "\\", str_replace("\r\n", "\n", $_POST['url']))),
                    ':info' => str_replace(' ', '\\ ', str_replace("\n", "\\", str_replace("\r\n", "\n", $_POST['info']))),
                    ':id' => $_POST['id']
                ]);
                $message = "Item updated successfully";
                $messageType = "success";
            } elseif ($action === 'delete') {
                $stmt = $pdo->prepare("DELETE FROM loginfo WHERE id = :id");
                $stmt->execute([':id' => $_POST['id']]);
                $message = "Item deleted successfully";
                $messageType = "success";
            }

            // Perform Search (Always refresh results after action)
            $sql = "SELECT * FROM loginfo WHERE account LIKE :query OR id LIKE :query";
            $searchParam = '%' . $query . '%';
            $stmt = $pdo->prepare($sql);
            $stmt->execute([':query' => $searchParam]);
            $results = $stmt->fetchAll(PDO::FETCH_ASSOC);

        } catch (Exception $e) {
            $message = $e->getMessage();
            $messageType = "error";
        }
    }
}
if(isset($_GET['get_settings'])) {
    header('Content-Type: application/json');
    echo json_encode(getSyncSettings());
    exit;
}
?>
<!DOCTYPE html>
<html>
<head>
    <title>Guardian Vault - Dark</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        :root {
            --primary: #4a9eff;
            --primary-light: #7cb9ff;
            --bg: #121212;
            --card-bg: #1e1e1e;
            --text: #e0e0e0;
            --text-muted: #aaaaaa;
            --input-bg: #2c2c2c;
            --danger: #ff5252;
            --success: #4caf50;
            --border: #333333;
        }

        body {
            font-family: 'Montserrat', Arial, sans-serif;
            margin: 0;
            padding: 40px 20px;
            background-color: var(--bg);
            color: var(--text);
        }

        .container {
            max-width: 560px;
            margin: auto;
        }

        .header-card {
            background-color: var(--card-bg);
            padding: 25px;
            border-radius: 12px;
            box-shadow: 0 4px 15px rgba(0,0,0,0.3);
            margin-bottom: 15px;
            text-align: center;
            border: 1px solid var(--border);
        }

        .logo-container img {
            max-width: 100%;
            margin-bottom: 15px;
            filter: drop-shadow(0 0 5px rgba(255,255,255,0.1));
        }

        .controls-row {
            display: flex;
            flex-wrap: nowrap;
            gap: 8px;
            align-items: center;
            margin: 0 auto 10px auto;
            width: calc(100% - 19px);
        }
        
        .flex-grow {
            flex: 1;
            min-width: 0; /* Prevents overflow */
        }

        select, input[type="text"], input[type="password"], textarea {
            padding: 8px 10px;
            border-radius: 6px;
            border: 1px solid var(--border);
            background-color: var(--input-bg);
            color: var(--text);
            font-size: 13px;
            outline: none;
            
            font-family: 'RobotoMono', monospace;
        }

        input:focus, select:focus, textarea:focus, input[type="password"]:focus, input[type="text"]:focus {
             box-shadow: none !important; outline: none !important;
        }

        button {
            background-color: var(--primary);
            color: #000;
            border: none;
            padding: 8px 15px;
            border-radius: 6px;
            cursor: pointer;
            font-weight: bold;
            transition: background 0.3s;
            display: inline-flex;
            align-items: center;
            gap: 5px;
            font-size: 13px;
            white-space: nowrap;
        }

        button:hover {
            background-color: var(--primary-light);
        }

        button.btn-danger {
            background-color: var(--danger);
            color: #fff;
        }
        
        button.btn-icon {
            padding: 4px;
            border-radius: 50%;
            background-color: transparent;
            color: var(--primary);
            min-width: auto;
        }
        
        button.btn-icon:hover {
            background-color: rgba(255,255,255,0.05);
        }
        
        button.btn-icon.delete {
            color: var(--danger);
        }

        .default-check {
            display: flex;
            align-items: center;
            gap: 4px;
            font-size: 0.8em;
            cursor: pointer;
            white-space: nowrap;
            margin-right: 5px;
            color: var(--text-muted);
        }

        .message {
            padding: 10px;
            border-radius: 8px;
            margin-bottom: 20px;
            text-align: center;
            font-size: 0.85rem;
        }
        .message.success { background-color: rgba(76, 175, 80, 0.2); color: #81c784; border: 1px solid #4caf50; }
        .message.error { background-color: rgba(244, 67, 54, 0.2); color: #e57373; border: 1px solid #f44336; }

        .sync-output {
            text-align: left;
            margin: 0 auto;
            max-width: 400px;
            padding: 10px;
            border-radius: 8px;
        }

        .sync-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 4px 8px;
            border-bottom: 1px solid #2a2a2a;
            font-family: 'RobotoMono', monospace;
            font-size: 0.85rem;
        }

        .sync-item:last-child {
            border-bottom: none;
        }

        .sync-item .db-name {
            color: #E3E3E3;
        }

        .sync-icon {
            width: 18px;
            height: 18px;
        }

        .sync-icon.synced { color: #4caf50; } /* Green Check */
        .sync-icon.push { color: #FF9800; }   /* Orange Up */
        .sync-icon.pull { color: #FFEB3B; }   /* Yellow Down */
        .sync-icon.error { color: #f44336; }  /* Red X */

        .sync-summary {
            margin-top: 10px;
            padding-top: 10px;
            border-top: 1px solid var(--border);
            font-size: 0.8rem;
            color: var(--text-muted);
            text-align: center;
        }

        .results-grid {
            display: flex;
            flex-direction: column;
            gap: 15px;
        }

        .account-card {
            background-color: var(--card-bg);
            border-radius: 12px;
            padding: 25px 20px 25px 10px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.3);
            border-left: 5px solid var(--primary);
            position: relative;
            width: 100%;
            box-sizing: border-box;
            font-size: 0.9rem;
            border-top: 1px solid var(--border);
            border-right: 1px solid var(--border);
            border-bottom: 1px solid var(--border);
        }
        
        .account-card:hover {
            box-shadow: 0 5px 15px rgba(0,0,0,0.5);
            border-color: #444;
        }

        .card-header {
            display: flex;
            align-items: flex-start;
            margin-bottom: 8px;
            border-bottom: 1px solid var(--border);
            padding-bottom: 8px;
        }
        
        .card-header h3 {
            margin: 0;
            font-size: 1rem;
            color: var(--primary);
            word-break: break-all;
            flex: 1;
        }

        .field-label.title {
            color: var(--primary);
            opacity: 0.7;
        }
        
        .card-actions {
            display: flex;
            gap: 2px;
            margin-left: 10px;
        }

        .field-row {
            display: flex;
            margin-bottom: 12px;
            font-size: 0.85rem;
            line-height: 1.4;
            word-break: break-all;
            font-family: 'RobotoMono', monospace;
            font-weight: 500;
        }
        
        .field-label {
            font-weight: 600;
            color: var(--text-muted);
            font-size: 0.75em;
            width: 85px;
            flex-shrink: 0;
            text-align: right;
            padding-right: 20px; /* Horizontal space between label and content */
            margin-top: 2px;
        }

        .field-content {
            flex: 1;
            min-width: 0;
        }
        
        .password-field, .copyable {
            cursor: pointer;
            background: #2a2a2a;
            padding: 2px 5px;
            border-radius: 4px;
            transition: background-color 0.2s;
            color: #d0d0d0;
        }
        
        .password-field:hover, .copyable:hover {
            background-color: #3a3a3a;
            color: #ffffff;
        }

        .linkify a {
            color: var(--primary-light);
            text-decoration: none;
        }
        .linkify a:hover {
            text-decoration: underline;
        }

        /* Modal */
        .modal-overlay {
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background: rgba(0,0,0,0.8);
            display: none;
            z-index: 1000;
            overflow-y: auto;
        }
        
        .modal-overlay.active {
            display: block; /* Changed from flex */
        }
        
        .modal {
            background: #252525;
            padding: 25px;
            border-radius: 12px;
            width: 90%;
            max-width: 500px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.5);
            border: 1px solid var(--border);
            color: var(--text);
            margin: 50px auto; /* Vertical stability */
            position: relative;
        }
        
        .modal h2 {
            margin-top: 0;
            color: var(--primary);
        }
        
        .form-group {
            margin-bottom: 12px;
        }
        
        .form-group label {
            display: block;
            margin-bottom: 5px;
            font-weight: bold;
            color: var(--text-muted);
        }
        
        .form-group input, .form-group textarea {
            width: 100%;
            box-sizing: border-box;
            background: var(--input-bg);
            border: 1px solid var(--border);
            padding: 10px;
            color: var(--text);
            border-radius: 8px;
            font-family: 'RobotoMono', monospace;
        }
        
        .form-group textarea {
            resize: none;
            min-height: 80px;
            overflow: hidden;
            line-height: 1.5;
            font-size: 13px;
        }
        
        .modal-actions {
            display: flex;
            justify-content: flex-end;
            gap: 10px;
            margin-top: 20px;
        }

        /* SVGs */
        .icon {
            width: 16px;
            height: 16px;
            fill: currentColor;
            display: block;
        }
    </style>
</head>
<body>

<div class="container">
    <div class="header-card">
        
        <?php if ($message): ?>
            <div class="message <?php echo $messageType; ?>"><?php echo $message; ?></div>
        <?php endif; ?>

        <form method="POST" id="searchForm">
            <input type="hidden" name="action" value="">
            <!-- Row 1: DB Select & Add -->
            <div class="controls-row">
                <select name="selected_db" onchange="this.form.submit()" class="flex-grow">
                    <?php foreach ($dbList as $db): ?>
                        <option value="<?php echo htmlspecialchars($db); ?>" <?php echo $db === $selectedDb ? 'selected' : ''; ?> >
                            <?php echo htmlspecialchars($db); ?>
                        </option>
                    <?php endforeach; ?>
                </select>
                
                <label class="default-check" title="Make this the default database">
                    <input type="checkbox" name="set_default" value="1" onchange="this.form.submit()"> Default
                </label>
                
                <button type="button" onclick="openAddModal()">
                    <svg class="icon" viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>
                    Add
                </button>
                <button type="button" onclick="document.querySelector('#searchForm input[name=action]').value='sync'; document.querySelector('#searchForm').submit();">
                    <svg class="icon" viewBox="0 0 24 24"><path d="M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>
                    Sync
                </button>
                <button type="button" onclick="openSettingsModal()">
                    <svg class="icon" viewBox="0 0 24 24"><path d="M19.14,12.94c0.04-0.3,0.06-0.61,0.06-0.94c0-0.32-0.02-0.64-0.07-0.94l2.03-1.58c0.18-0.14,0.23-0.41,0.12-0.61 l-1.92-3.32c-0.12-0.22-0.37-0.29-0.59-0.22l-2.39,0.96c-0.5-0.38-1.03-0.7-1.62-0.94L14.4,2.81c-0.04-0.24-0.24-0.41-0.48-0.41h-3.84 c-0.24,0-0.43,0.17-0.47,0.41L9.25,5.35C8.66,5.59,8.12,5.92,7.63,6.29L5.24,5.33c-0.22-0.08-0.47,0-0.59,0.22L2.74,8.87 C2.62,9.08,2.66,9.34,2.86,9.48l2.03,1.58C4.84,11.36,4.8,11.69,4.8,12s0.02,0.64,0.07,0.94l-2.03,1.58 c-0.18,0.14-0.23-0.41-0.12-0.61l1.92,3.32c0.12,0.22,0.37,0.29,0.59,0.22l2.39-0.96c0.5,0.38,1.03,0.7,1.62,0.94l0.36,2.54 c0.04,0.24,0.24,0.41,0.48,0.41h3.84c0.24,0,0.44-0.17,0.47-0.41l0.36-2.54c0.59-0.24,1.13-0.56,1.62-0.94l2.39,0.96 c0.22,0.08,0.47,0,0.59-0.22l1.92-3.32c0.12-0.22,0.07-0.47-0.12-0.61L19.14,12.94z M12,15.6c-1.98,0-3.6-1.62-3.6-3.6 s1.62-3.6,3.6-3.6s3.6,1.62,3.6,3.6S13.98,15.6,12,15.6z"/></svg>
                </button>
            </div>

            <!-- Row 2: Search Controls -->
            <div class="controls-row">
                <input type="text" name="query" placeholder="Search Term..." value="<?php echo htmlspecialchars($query); ?>" autocomplete="off" class="flex-grow">
                <input type="password" name="dkey" id="mainKey" placeholder="Database Key" value="<?php echo htmlspecialchars($dkey); ?>" class="flex-grow">
                <button type="submit" onclick="document.querySelector('#searchForm input[name=action]').value='';">
                    <svg class="icon" viewBox="0 0 24 24"><path d="M15.5 14h-.79l-.28-.27C15.41 12.59 16 11.11 16 9.5 16 5.91 13.09 3 9.5 3S3 5.91 3 9.5 5.91 16 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z"/></svg>
                    Search
                </button>
            </div>
        </form>
    </div>

    <div class="results-grid">
        <?php foreach ($results as $result): ?>
        <div class="account-card">
            <div class="card-header">
                <span class="field-label title">Account</span>
                <h3><?php echo htmlspecialchars(str_replace('\\', '', str_replace('\\ ', ' ', $result['account']))); ?></h3>
                <div class="card-actions">
                    <button class="btn-icon" onclick='openEditModal(<?php echo json_encode($result); ?>)' title="Edit">
                        <svg class="icon" viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                    </button>
                    <button class="btn-icon delete" onclick="confirmDelete(<?php echo $result['id']; ?>)" title="Delete">
                        <svg class="icon" viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>
                    </button>
                </div>
            </div>
            
            <?php if (!empty($result['login'])): ?>
            <div class="field-row">
                <span class="field-label">Login</span>
                <div class="field-content">
                    <span class="copyable" style="white-space: pre-wrap;" onclick="copyToClipboard(this)" title="Click to copy"><?php echo htmlspecialchars(str_replace('\\', "\n", str_replace('\\ ', ' ', $result['login']))); ?></span>
                </div>
            </div>
            <?php endif; ?>
            
            <?php if (!empty($result['passwd'])): ?>
            <div class="field-row">
                <span class="field-label">Password</span>
                <div class="field-content">
                    <span class="password-field" style="white-space: pre-wrap;" onclick="copyToClipboard(this)" title="Click to copy"><?php echo htmlspecialchars(str_replace('\\', "\n", str_replace('\\ ', ' ', $result['passwd']))); ?></span>
                </div>
            </div>
            <?php endif; ?>
            
            <?php if (!empty($result['url'])): ?>
            <div class="field-row">
                <span class="field-label">URL</span>
                <div class="field-content">
                    <span class="linkify" style="white-space: pre-wrap;"><?php echo htmlspecialchars(str_replace('\\', "\n", str_replace('\\ ', ' ', $result['url']))); ?></span>
                </div>
            </div>
            <?php endif; ?>
            
            <?php if (!empty($result['info'])): ?>
            <div class="field-row">
                <span class="field-label">Info</span>
                <div class="field-content">
                    <div style="white-space: pre-wrap;"><?php echo htmlspecialchars(str_replace('\\', "\n", str_replace('\\ ', ' ', $result['info']))); ?></div>
                </div>
            </div>
            <?php endif; ?>
        </div>
        <?php endforeach; ?>
    </div>
</div>

<!-- Add/Edit Modal -->
<div class="modal-overlay" id="itemModal">
    <div class="modal">
        <h2 id="modalTitle">Add Item</h2>
        <form method="POST">
            <input type="hidden" name="selected_db" value="<?php echo htmlspecialchars($selectedDb); ?>">
            <input type="hidden" name="dkey" id="modalKey">
            <input type="hidden" name="action" id="modalAction" value="add">
            <input type="hidden" name="id" id="modalId">
            <input type="hidden" name="query" value="<?php echo htmlspecialchars($query); ?>">

            <div class="form-group">
                <label>Account</label>
                <input type="text" name="account" id="inputAccount" required>
            </div>
            <div class="form-group">
                <label>Login</label>
                <input type="text" name="login" id="inputLogin">
            </div>
            <div class="form-group">
                <label>Password</label>
                <input type="text" name="passwd" id="inputPasswd">
            </div>
            <div class="form-group">
                <label>URL</label>
                <input type="text" name="url" id="inputUrl">
            </div>
            <div class="form-group">
                <label>Info</label>
                <textarea name="info" id="inputInfo"></textarea>
            </div>

            <div class="modal-actions">
                <button type="button" onclick="closeModal()" style="background-color: #444;">Cancel</button>
                <button type="submit">Save</button>
            </div>
        </form>
    </div>
</div>

<!-- Settings Modal -->
<div class="modal-overlay" id="settingsModal">
    <div class="modal">
        <h2>Sync Settings</h2>
        <form method="POST">
            <input type="hidden" name="action" value="save_settings">
            <div class="form-group">
                <label>SSH Server</label>
                <input type="text" name="server" id="inputServer">
            </div>
            <div class="form-group">
                <label>Port</label>
                <input type="text" name="port" id="inputPort">
            </div>
            <div class="form-group">
                <label>User</label>
                <input type="text" name="user" id="inputUser">
            </div>
            <div class="form-group">
                <label>Remote Directory</label>
                <input type="text" name="remote_dir" id="inputRemoteDir">
            </div>
            <div class="form-group">
                <label>SSH Password</label>
                <input type="password" name="password" id="inputSshPassword">
            </div>
            <div class="modal-actions">
                <button type="button" onclick="closeSettingsModal()" style="background-color: #444;">Cancel</button>
                <button type="submit">Save</button>
            </div>
        </form>
    </div>
</div>

<!-- Delete Form (Hidden) -->
<form id="deleteForm" method="POST" style="display:none;">
    <input type="hidden" name="selected_db" value="<?php echo htmlspecialchars($selectedDb); ?>">
    <input type="hidden" name="dkey" id="deleteKey">
    <input type="hidden" name="action" value="delete">
    <input type="hidden" name="id" id="deleteId">
    <input type="hidden" name="query" value="<?php echo htmlspecialchars($query); ?>">
</form>

<script>
    function closeModal() {
        document.getElementById('itemModal').classList.remove('active');
        document.body.style.overflow = ''; // Restore scroll
    }

    function closeSettingsModal() {
        document.getElementById('settingsModal').classList.remove('active');
        document.body.style.overflow = ''; // Restore scroll
    }

    function openSettingsModal() {
        fetch('?get_settings=true')
            .then(response => response.json())
            .then(data => {
                document.getElementById('inputServer').value = data.server;
                document.getElementById('inputPort').value = data.port;
                document.getElementById('inputUser').value = data.user;
                document.getElementById('inputRemoteDir').value = data.remote_dir;
                document.getElementById('inputSshPassword').value = data.password;
                document.getElementById('settingsModal').classList.add('active');
                document.body.style.overflow = 'hidden'; // Prevent body scroll
            });
    }

    function autoResize(textarea) {
        const overlay = document.getElementById('itemModal');
        const scrollPos = overlay.scrollTop;
        
        textarea.style.height = 'auto';
        textarea.style.height = (textarea.scrollHeight) + 'px';
        
        // Preserve position precisely
        overlay.scrollTop = scrollPos;
    }

    function openAddModal() {
        if (!checkKey()) return;
        document.getElementById('modalTitle').innerText = 'Add Item';
        document.getElementById('modalAction').value = 'add';
        document.getElementById('modalId').value = '';
        document.getElementById('modalKey').value = document.getElementById('mainKey').value;
        
        // Clear fields
        ['inputAccount', 'inputLogin', 'inputPasswd', 'inputUrl', 'inputInfo'].forEach(id => {
            document.getElementById(id).value = '';
        });

        const infoTextarea = document.getElementById('inputInfo');
        infoTextarea.style.height = '80px'; // Reset to min-height
        
        document.getElementById('itemModal').classList.add('active');
        document.body.style.overflow = 'hidden'; // Prevent body scroll
    }

    function openEditModal(data) {
        if (!checkKey()) return;
        document.getElementById('modalTitle').innerText = 'Edit Item';
        document.getElementById('modalAction').value = 'edit';
        document.getElementById('modalId').value = data.id;
        document.getElementById('modalKey').value = document.getElementById('mainKey').value;
        
        const unescape = (str) => {
            if (!str) return '';
            // First unescape spaces '\ ' -> ' ', then newlines '\' -> '\n'
            return str.replace(/\\ /g, ' ').replace(/\\/g, '\n');
        };

        document.getElementById('inputAccount').value = unescape(data.account);
        document.getElementById('inputLogin').value = unescape(data.login);
        document.getElementById('inputPasswd').value = unescape(data.passwd);
        document.getElementById('inputUrl').value = unescape(data.url);
        const infoTextarea = document.getElementById('inputInfo');
        infoTextarea.value = unescape(data.info);
        
        document.getElementById('itemModal').classList.add('active');
        document.body.style.overflow = 'hidden'; // Prevent body scroll
        autoResize(infoTextarea);
    }

    function confirmDelete(id) {
        if (!checkKey()) return;
        if (confirm('Are you sure you want to delete this item?')) {
            document.getElementById('deleteId').value = id;
            document.getElementById('deleteKey').value = document.getElementById('mainKey').value;
            document.getElementById('deleteForm').submit();
        }
    }

    function checkKey() {
        const key = document.getElementById('mainKey').value;
        if (!key) {
            alert('Please enter the Database Key first.');
            document.getElementById('mainKey').focus();
            return false;
        }
        return true;
    }

    // Copy to Clipboard
    function copyToClipboard(el) {
        const text = el.innerText;
        
        // Function to show feedback
        const showFeedback = () => {
             const originalBg = el.style.backgroundColor;
             el.style.backgroundColor = '#1b5e20'; // Dark green success color
             setTimeout(() => {
                 el.style.backgroundColor = originalBg || ''; // Revert
             }, 500);
        };

        if (navigator.clipboard && window.isSecureContext) {
            navigator.clipboard.writeText(text).then(showFeedback).catch(err => {
                console.error('Failed to copy: ', err);
                fallbackCopy(text, el);
            });
        } else {
            fallbackCopy(text, el);
        }
        
        function fallbackCopy(text, el) {
            let textArea = document.createElement("textarea");
            textArea.value = text;
            textArea.style.position = "fixed";
            textArea.style.left = "-9999px";
            document.body.appendChild(textArea);
            textArea.focus();
            textArea.select();
            try {
                document.execCommand('copy');
                showFeedback();
            } catch (err) {
                console.error('Fallback: Oops, unable to copy', err);
            }
            document.body.removeChild(textArea);
        }
    }

    // Auto-Linkify
    document.addEventListener('DOMContentLoaded', function () {
        const infoTextarea = document.getElementById('inputInfo');
        infoTextarea.addEventListener('input', function() {
            autoResize(this);
        });

        var urlPattern = /(https?:\/\/[^\s]+)/g;
        document.querySelectorAll('.linkify').forEach(function(el) {
            var text = el.innerHTML;
            var newText = text.replace(urlPattern, function(url) {
                return '<a href="' + url + '" target="_blank">' + url + '</a>';
            });
            el.innerHTML = newText;
        });
    });
</script>
</body>
</html>
