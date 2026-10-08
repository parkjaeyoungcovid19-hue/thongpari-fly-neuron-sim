import Foundation

extension KeyedDecodingContainer {
    func lossy<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

func unit<T: BinaryFloatingPoint>(_ value: T) -> T { min(1, max(0, value)) }
