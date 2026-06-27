import Foundation
import Network
import SwiftUI
import Combine

class MacServer: ObservableObject {
    private var listener: NWListener?
    @Published var connection: NWConnection?
    @Published var messages: [String] = []
    @Published var status: String = "Stopped"
    
    let port: NWEndpoint.Port = 12345
    
    func start() {
        do {
            listener = try NWListener(using: .tcp, on: port)
            listener?.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.status = "Listening on port \(self?.port.rawValue ?? 0)"
                    case .failed(let error):
                        self?.status = "Failed: \(error.localizedDescription)"
                    default:
                        break
                    }
                }
            }
            
            listener?.newConnectionHandler = { [weak self] newConnection in
                self?.setupConnection(newConnection)
            }
            
            listener?.start(queue: .main)
        } catch {
            status = "Start failed: \(error.localizedDescription)"
        }
    }
    
    private func setupConnection(_ connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.status = "Connected to client"
                    self?.receive()
                case .failed(let error):
                    self?.status = "Connection failed: \(error.localizedDescription)"
                    self?.connection = nil
                case .cancelled:
                    self?.status = "Connection cancelled"
                    self?.connection = nil
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }
    
    func send(message: String) {
        guard let connection = connection else { return }
        let data = (message + "\n").data(using: .utf8) ?? Data()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.messages.append("Send failed: \(error.localizedDescription)")
                }
            }
        })
    }
    
    private func receive() {
        guard let connection = connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                if let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    DispatchQueue.main.async {
                        self?.messages.append("Client: \(message)")
                    }
                }
            }
            if isComplete {
                DispatchQueue.main.async {
                    self?.status = "Connection closed by client"
                    self?.connection = nil
                }
            } else if error == nil {
                self?.receive()
            }
        }
    }
}

struct ServerView: View {
    @StateObject private var server = MacServer()
    @State private var textToSend: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("macOS Display Server")
                .font(.title)
                .bold()
            
            Text("Status: \(server.status)")
                .foregroundColor(.secondary)
            
            Button("Start Server") {
                server.start()
            }
            .buttonStyle(.borderedProminent)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(server.messages, id: \.self) { message in
                        Text(message)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
                }
            }
            .frame(height: 150)
            .background(Color.black.opacity(0.1))
            .cornerRadius(8)
            
            HStack {
                TextField("Message", text: $textToSend)
                    .textFieldStyle(.roundedBorder)
                
                Button("Send Ping") {
                    server.send(message: textToSend.isEmpty ? "Ping" : textToSend)
                    textToSend = ""
                }
                .disabled(server.connection == nil)
            }
        }
        .padding()
        .frame(width: 400, height: 400)
    }
}
