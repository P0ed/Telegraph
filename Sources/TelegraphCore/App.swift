import Foundation
import Darwin

@MainActor
public enum TelegraphApp {
    public static func run() async {
        setlocale(LC_CTYPE, "")
        do { Darwin.exit(try await execute(Array(CommandLine.arguments.dropFirst()))) }
        catch {
            let message = TerminalText.clean(describe(error))
            try? FileHandle.standardError.write(contentsOf: Data("telegraph: \(message)\n".utf8))
            Darwin.exit(1)
        }
    }
    private static func execute(_ arguments: [String]) async throws -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            print("""
            Telegraph 0.1.0 — Telegram direct messages in your terminal

            Usage: telegraph [--test-server]
                   telegraph logout [--test-server]
                   telegraph --help | --version

            First launch asks for your API ID/hash from https://my.telegram.org,
            phone number, Telegram login code, and optional 2FA password.
            Credentials and sessions are stored in your macOS Keychain.

            Tab cycles chats, history, and composer. Arrows select; Enter opens
            a chat/media or sends text. PgUp/PgDn scroll; Ctrl-J inserts a newline.
            Click [Image], [Video], or [GIF] to download and open with Quick Look.
            Ctrl-C or Ctrl-D exits. Escape returns to the chat list.

            Downloads: ~/Downloads/Telegraph/<account-id>/
            Requires macOS 27 and an interactive terminal. One account per profile.
            --test-server uses Telegram's separate test network and Keychain entry.
            """)
            return 0
        }
        if arguments == ["--version"] { print("telegraph 0.1.0"); return 0 }
        let test = arguments.contains("--test-server")
        let commands = arguments.filter { $0 != "--test-server" }
        guard commands.isEmpty || commands == ["logout"],
              arguments.filter({ $0 == "--test-server" }).count <= 1 else {
            throw TelegraphError.invalid("Usage: telegraph [logout] [--test-server]; use --help for details")
        }
        let terminal = try TerminalIO()
        terminal.onSignal = { signal in
            if signal == SIGWINCH { return }
            if signal == SIGTSTP { terminal.suspend(); return }
            if signal == SIGCONT { terminal.resumePrompt(); return }
            terminal.restore(); Darwin.exit(128 + signal)
        }
        defer { terminal.restore() }
        let lock = try ClientLock(test: test)
        defer { withExtendedLifetime(lock) {} }
        var stored = try ProfileStore.load(test: test)
        if commands == ["logout"], stored == nil { print("No stored session."); return 0 }
        if stored == nil {
            terminal.write("Telegraph — private Telegram chats\nCreate application credentials at https://my.telegram.org → API development tools.\n")
            var id: Int32?
            while id == nil {
                let input = try await terminal.readPrompt("API ID: ").trimmingCharacters(in: .whitespaces)
                if let number = Int32(input), number > 0 { id = number }
                else { terminal.write("Enter the numeric API ID.\n") }
            }
            var hash = ""
            while hash.count != 32 || !hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                hash = try await terminal.readPrompt("API hash: ", hidden: true).trimmingCharacters(in: .whitespaces).lowercased()
                if hash.count != 32 { terminal.write("The API hash must contain 32 hexadecimal characters.\n") }
            }
            stored = ClientProfile(apiID: id!, apiHash: hash)
            try ProfileStore.save(stored!, test: test)
        }
        let client = try TelegramClient(profile: stored!, test: test)
        do {
            if commands == ["logout"] {
                terminal.write("Revoking Telegraph sessions…\n")
                try await client.logout()
                terminal.write("Logged out. Downloaded media remains in Downloads.\n")
                return 0
            }
            if await client.hasSession {
                terminal.write("Connecting to Telegram…\n")
                do { try await client.validateSession() }
                catch let error as TelegraphError where ["AUTH_KEY_UNREGISTERED", "SESSION_REVOKED", "SESSION_EXPIRED", "AUTH_KEY_DUPLICATED"].contains(error.rpcMessage ?? "") {
                    try await client.clearExpiredSession()
                    terminal.write("The saved session expired. Sign in again.\n")
                }
            }
            if !(await client.hasSession) { try await login(client: client, terminal: terminal) }
            let account = await client.accountID()
            let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(test ? "Downloads/Telegraph/test" : "Downloads/Telegraph")
            let ui = TerminalUI(terminal: terminal, client: client, downloadRoot: base.appendingPathComponent(String(account)))
            let code = try await ui.run()
            await client.close()
            return code
        } catch { await client.close(); throw error }
    }

    private static func login(client: TelegramClient, terminal: TerminalIO) async throws {
        terminal.write("Sign in to an existing Telegram account. Codes may arrive in your Telegram app rather than SMS.\n")
        var phone = ""
        while true {
            let input = try await terminal.readPrompt("Phone number (with country code): ")
            phone = input.filter { $0 == "+" || ($0 >= "0" && $0 <= "9") }
            let digits = phone.filter { $0 != "+" }
            if (5...15).contains(digits.count), !phone.dropFirst().contains("+") { break }
            terminal.write("Enter a phone number including its country code.\n")
        }
        var sent = try await client.beginLogin(phone: phone)
        while !(await client.hasSession) {
            let delivery = try deliveryDescription(sent)
            terminal.write(delivery + "\n")
            let resendAt = Date().addingTimeInterval(Double(sent["timeout"].int))
            while true {
                let code = try await terminal.readPrompt("Login code (or 'resend'): ", hidden: true).trimmingCharacters(in: .whitespaces)
                if code.lowercased() == "resend" {
                    guard sent.fields["next_type"] != nil else { terminal.write("Telegram has not offered another code delivery method.\n"); continue }
                    guard Date() >= resendAt else {
                        terminal.write("Wait \(Int(ceil(resendAt.timeIntervalSinceNow))) seconds before requesting another code.\n"); continue
                    }
                    sent = try await client.resendCode(phone: phone, hash: sent["phone_code_hash"].string)
                    break
                }
                guard !code.isEmpty else { continue }
                do { try await client.submitCode(phone: phone, sent: sent, code: code); return }
                catch let error as TelegraphError {
                    switch error.rpcMessage {
                    case "SESSION_PASSWORD_NEEDED":
                        while true {
                            let password = try await terminal.readPrompt("2FA password: ", hidden: true)
                            do { try await client.submitPassword(password); return }
                            catch let error as TelegraphError where error.rpcMessage == "PASSWORD_HASH_INVALID" {
                                terminal.write("Incorrect password. Try again.\n")
                            }
                        }
                    case "PHONE_CODE_INVALID", "PHONE_CODE_EMPTY":
                        terminal.write("Incorrect code. Try again.\n")
                    case "PHONE_CODE_EXPIRED":
                        terminal.write("Code expired. Requesting a new code…\n")
                        sent = try await client.beginLogin(phone: phone)
                        break
                    default: throw error
                    }
                    if error.rpcMessage == "PHONE_CODE_EXPIRED" { break }
                }
            }
        }
    }
    private static func deliveryDescription(_ sent: TLObject) throws -> String {
        guard sent.name == "auth.sentCode", let type = sent["type"].object else {
            throw TelegraphError.invalid("Telegram requires a login flow this client does not support")
        }
        switch type.name {
        case "auth.sentCodeTypeApp": return "Enter the code sent to your other Telegram sessions."
        case "auth.sentCodeTypeSms", "auth.sentCodeTypeSmsWord", "auth.sentCodeTypeSmsPhrase": return "Enter the code, word, or phrase sent by SMS."
        case "auth.sentCodeTypeCall": return "Enter the code from Telegram's phone call."
        case "auth.sentCodeTypeMissedCall": return "Enter the last digits of the calling number (\(type["length"].int) digits)."
        case "auth.sentCodeTypeFlashCall": return "Enter the calling phone number matching \(type["pattern"].string)."
        case "auth.sentCodeTypeEmailCode": return "Enter the code sent to \(type["email_pattern"].string)."
        case "auth.sentCodeTypeFragmentSms": return "Retrieve your code at \(TerminalText.clean(type["url"].string))."
        default: throw TelegraphError.invalid("Telegram selected a login delivery method unavailable to this client. Use an official app to set up an available code method, then retry.")
        }
    }
}
