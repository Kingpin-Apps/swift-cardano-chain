import Testing
import Foundation
@testable import SwiftCardanoChain

@Suite("Cache Tests")
struct CacheTests {

    @Test("Insert and retrieve value")
    func testInsertAndRetrieveValue() async throws {
        // Given
        let mockDate = Date()
        let dateProvider = { mockDate }
        let cache = Cache<String, String>(dateProvider: dateProvider, entryLifetime: 10)
        let key = "test-key"
        let value = "test-value"

        // When
        cache.insert(value, forKey: key)
        let retrievedValue = cache.value(forKey: key)

        // Then
        #expect(retrievedValue == value)
    }

    @Test("Value is accessible within lifetime")
    func testValueExpirationWithinLifetime() async throws {
        // Given
        var mockDate = Date()
        let dateProvider = { mockDate }
        let cache = Cache<String, String>(dateProvider: dateProvider, entryLifetime: 10)
        let key = "test-key"
        let value = "test-value"
        cache.insert(value, forKey: key)

        // When - advance time but still within lifetime
        mockDate = mockDate.addingTimeInterval(5)
        let retrievedValue = cache.value(forKey: key)

        // Then
        #expect(retrievedValue == value)
    }

    @Test("Value expires after lifetime")
    func testValueExpirationAfterLifetime() async throws {
        // Given
        var mockDate = Date()
        let dateProvider = { mockDate }
        let cache = Cache<String, String>(dateProvider: dateProvider, entryLifetime: 10)
        let key = "test-key"
        let value = "test-value"
        cache.insert(value, forKey: key)

        // When - advance time beyond lifetime
        mockDate = mockDate.addingTimeInterval(15)
        let retrievedValue = cache.value(forKey: key)

        // Then
        #expect(retrievedValue == nil)
    }

    @Test("Remove value from cache")
    func testRemoveValue() async throws {
        // Given
        let mockDate = Date()
        let dateProvider = { mockDate }
        let cache = Cache<String, String>(dateProvider: dateProvider, entryLifetime: 10)
        let key = "test-key"
        let value = "test-value"
        cache.insert(value, forKey: key)

        // When
        cache.removeValue(forKey: key)
        let retrievedValue = cache.value(forKey: key)

        // Then
        #expect(retrievedValue == nil)
    }

    @Test("Subscript getter retrieves value")
    func testSubscriptGetter() async throws {
        // Given
        let mockDate = Date()
        let dateProvider = { mockDate }
        let cache = Cache<String, String>(dateProvider: dateProvider, entryLifetime: 10)
        let key = "test-key"
        let value = "test-value"
        cache.insert(value, forKey: key)

        // When
        let retrievedValue = cache[key]

        // Then
        #expect(retrievedValue == value)
    }

    @Test("Subscript setter stores value")
    func testSubscriptSetter() async throws {
        // Given
        let mockDate = Date()
        let dateProvider = { mockDate }
        let cache = Cache<String, String>(dateProvider: dateProvider, entryLifetime: 10)
        let key = "test-key"
        let value = "test-value"

        // When
        cache[key] = value
        let retrievedValue = cache.value(forKey: key)

        // Then
        #expect(retrievedValue == value)
    }

    @Test("Subscript setter with nil removes value")
    func testSubscriptSetterWithNil() async throws {
        // Given
        let mockDate = Date()
        let dateProvider = { mockDate }
        let cache = Cache<String, String>(dateProvider: dateProvider, entryLifetime: 10)
        let key = "test-key"
        let value = "test-value"
        cache[key] = value

        // When
        cache[key] = nil
        let retrievedValue = cache.value(forKey: key)

        // Then
        #expect(retrievedValue == nil)
    }

    @Test("Cache handles multiple keys and values")
    func testMultipleKeysAndValues() async throws {
        // Given
        let mockDate = Date()
        let dateProvider = { mockDate }
        let cache = Cache<String, String>(dateProvider: dateProvider, entryLifetime: 10)
        let keys = ["key1", "key2", "key3"]
        let values = ["value1", "value2", "value3"]

        // When
        for (index, key) in keys.enumerated() {
            cache[key] = values[index]
        }

        // Then
        for (index, key) in keys.enumerated() {
            #expect(cache[key] == values[index])
        }
    }

    @Test("Cache works with different value types")
    func testCacheWithDifferentTypes() async throws {
        // Given
        let mockDate = Date()
        let dateProvider = { mockDate }
        let intCache = Cache<String, Int>(dateProvider: dateProvider, entryLifetime: 10)
        let key = "number-key"
        let value = 42

        // When
        intCache[key] = value
        let retrievedValue = intCache[key]

        // Then
        #expect(retrievedValue == value)
    }

    @Test("Cache works with custom key types")
    func testCacheWithCustomKeyType() async throws {
        // Given
        struct CustomKey: Hashable {
            let id: String
        }

        let mockDate = Date()
        let dateProvider = { mockDate }
        let customCache = Cache<CustomKey, String>(dateProvider: dateProvider, entryLifetime: 10)
        let key = CustomKey(id: "custom-id")
        let value = "custom-value"

        // When
        customCache[key] = value
        let retrievedValue = customCache[key]

        // Then
        #expect(retrievedValue == value)
    }
}
