import Foundation
import Network
import SwiftUI
import Combine

class IPadClient: ObservableObject {
    private var connection: NWConnection?
    @Published var messages: [String] = []
    @Published var status: String = "Disconnected"
    
    func connect(host: String, port: UInt16) {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        
        connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.status = "Connected"
                    self?.receive()
                case .failed(let error):
                    self?.status = "Failed: \(error.localizedDescription)"
                case .cancelled:
                    self?.status = "Disconnected"
                default:
                    break
                }
            }
        }
        connection?.start(queue: .main)
    }
    
    func disconnect() {
        connection?.cancel()
        connection = nil
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
                        self?.messages.append("Server: \(message)")
                    }
                }
            }
            if isComplete {
                DispatchQueue.main.async {
                    self?.status = "Disconnected by server"
                    self?.connection = nil
                }
            } else if error == nil {
                self?.receive()
            }
        }
    }
}

struct ClientView: View {
    @StateObject private var client = IPadClient()
    @State private var hostAddress: String = "192.168.1.10"
    @State private var textToSend: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("iPad Display Client")
                .font(.title)
                .bold()
            
            Text("Status: \(client.status)")
                .foregroundColor(.secondary)
            
            HStack {
                TextField("Server IP", text: $hostAddress)
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                
                Button("Connect") {
                    client.connect(host: hostAddress, port: 12345)
                }
                .disabled(client.status == "Connected")
                
                Button("Disconnect") {
                    client.disconnect()
                }
                .disabled(client.status != "Connected")
            }
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(client.messages, id: \.self) { message in
                        Text(message)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
                }
            }
            .frame(height: 150)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            
            HStack {
                TextField("Message", text: $textToSend)
                    .textFieldStyle(.roundedBorder)
                
                Button("Send Ping") {
                    client.send(message: textToSend.isEmpty ? "Ping" : textToSend)
                    textToSend = ""
                }
                .disabled(client.status != "Connected")
            }
        }
        .padding()
    }
}
