import Foundation
import GozarCore
import Network

func tcpParameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    return NWParameters(tls: nil, tcp: tcp)
}

func loopbackListener(port: UInt16) throws -> NWListener {
    let parameters = tcpParameters()
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    parameters.acceptLocalOnly = true
    return try NWListener(using: parameters)
}

func makeConnection(_ destination: SocksWire.Destination) -> NWConnection {
    NWConnection(
        host: NWEndpoint.Host(destination.host),
        port: NWEndpoint.Port(rawValue: destination.port)!,
        using: tcpParameters()
    )
}

func elapsedMilliseconds(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
}

struct TransportFailure: LocalizedError {
    let message: String
    var reply: UInt8 = 1
    var errorDescription: String? { message }
}

// Exact reads keep a pipelined TCP payload in Network.framework until splicing starts.
func readFrame<Value: Equatable>(
    _ connection: NWConnection, prefix: [UInt8] = [],
    parse: @escaping ([UInt8]) -> SocksWire.Parse<Value>,
    completion: @escaping (Result<SocksWire.Parse<Value>, Error>) -> Void
) {
    let result = parse(prefix)
    guard case .need(let end) = result else {
        completion(.success(result))
        return
    }
    let count = end - prefix.count
    connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, eof, error in
        if let error {
            completion(.failure(error))
        } else if let data, !data.isEmpty, data.count == count || !eof {
            readFrame(connection, prefix: prefix + data, parse: parse, completion: completion)
        } else {
            completion(.failure(TransportFailure(message: "Connection closed during handshake")))
        }
    }
}

func connectThroughSocks(
    _ connection: NWConnection, to destination: SocksWire.Destination,
    completion: @escaping (Error?) -> Void
) {
    guard let request = SocksWire.upstreamRequest(destination) else {
        completion(TransportFailure(message: "Invalid SOCKS upstream destination"))
        return
    }
    connection.send(content: Data([5, 1, 0]), completion: .contentProcessed { error in
        if let error { completion(error); return }
        readFrame(connection, parse: { bytes -> SocksWire.Parse<UInt8> in
            guard bytes.count >= 2 else { return .need(2) }
            return bytes == [5, 0] ? .value(0) : .reject(1)
        }) { method in
            switch method {
            case .failure(let error): completion(error)
            case .success(.value):
                connection.send(content: request, completion: .contentProcessed { error in
                    if let error { completion(error); return }
                    readFrame(connection, parse: SocksWire.upstreamReply) { reply in
                        switch reply {
                        case .success(.value): completion(nil)
                        case .success(.reject(let code)):
                            completion(TransportFailure(message: "Upstream SOCKS CONNECT failed", reply: code))
                        case .failure(let error): completion(error)
                        case .success(.need): preconditionFailure("Incomplete SOCKS reply")
                        }
                    }
                })
            case .success(.reject): completion(TransportFailure(message: "Upstream refused SOCKS no-auth"))
            case .success(.need): preconditionFailure("Incomplete SOCKS negotiation")
            }
        }
    })
}

func connectionReply(for error: Error) -> UInt8 {
    switch error {
    case let failure as TransportFailure: return failure.reply
    case NWError.posix(.ECONNREFUSED): return 5
    case NWError.posix(.ENETUNREACH): return 3
    case NWError.posix(.EHOSTUNREACH), NWError.dns: return 4
    default: return 1
    }
}
