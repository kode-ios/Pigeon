//
//  Query.swift
//  Pigeon
//
//  Created by Fernando Martín Ortiz on 23/08/2020.
//  Copyright © 2020 Fernando Martín Ortiz. All rights reserved.
//

import Foundation
import Combine

public final class Query<Request, Response: Codable>: ObservableObject, QueryType, QueryInvalidationListener {
    public enum FetchingBehavior {
        case startWhenRequested
        case startImmediately(Request)
    }
    public enum PollingBehavior {
        case noPolling
        case pollEvery(TimeInterval)
    }
    var id: Int?
    public typealias State = QueryState<Response>
    public typealias QueryFetcher = (Request) -> AnyPublisher<Response, Error>
    
    @Published private(set) public var state = State.idle
    public var statePublisher: AnyPublisher<QueryState<Response>, Never> {
        return $state.eraseToAnyPublisher()
    }
    public var valuePublisher: AnyPublisher<Response, Never> {
        $state
            .map { $0.value }
            .filter({ $0 != nil })
            .map { $0! }
            .eraseToAnyPublisher()
    }
    private let key: QueryKey
    private let keyAdapter: (QueryKey, Request) -> QueryKey
    private let pollingBehavior: PollingBehavior
    private let cache: QueryCacheType
    private let cacheConfig: QueryCacheConfig
    private let fetcher: QueryFetcher
    private var lastRequest: Request?
    private var cancellables = Set<AnyCancellable>()
    private var timerCancellables = Set<AnyCancellable>()
    
    public init(
        key: QueryKey,
        keyAdapter: @escaping (QueryKey, Request) -> QueryKey = { key, _ in key },
        behavior: FetchingBehavior = .startWhenRequested,
        pollingBehavior: PollingBehavior = .noPolling,
        cache: QueryCacheType = QueryCache.global,
        cacheConfig: QueryCacheConfig = .global,
        fetcher: @escaping QueryFetcher
    ) {
        self.key = key
        self.keyAdapter = keyAdapter
        self.pollingBehavior = pollingBehavior
        self.cache = cache
        self.cacheConfig = cacheConfig
        self.fetcher = fetcher
        
        start(for: behavior)
        
        listenQueryInvalidation(for: key)
            .sink { (parameters: QueryInvalidator.TypedParameters<Request>) in
                switch parameters {
                case .lastData:
                    if let lastRequest = self.lastRequest {
                        self.refetch(request: lastRequest)
                    }
                case let .newData(newRequest):
                    self.refetch(request: newRequest)
                }
            }
            .store(in: &cancellables)
        
        QueryRegistry.shared.register(self.eraseToAnyQuery(), for: key)
    }
    
    deinit {
        QueryRegistry.shared.unregister(for: key)
    }
    
    public func refetch(request: Request) {
        lastRequest = request
        timerCancellables.forEach({ $0.cancel() })
        
        if cacheConfig.usagePolicy == .useIfFetchFails
            || (cacheConfig.usagePolicy == .useAndThenFetchIgnoringFails
                && state.isFailed) {
            state = .loading
        }

        performFetch(for: request)
        startPollingIfNeeded(for: request)
    }
    
    private func start(for behavior: FetchingBehavior) {
        switch behavior {
        case .startWhenRequested:
            if cacheConfig.usagePolicy == .useInsteadOfFetching
                || cacheConfig.usagePolicy == .useAndThenFetch
                || cacheConfig.usagePolicy == .useAndThenFetchIgnoringFails {
                if let cachedResponse: Response = self.getCacheValueIfPossible(for: key) {
                    state = .succeed(cachedResponse)
                }
            }
            break
        case let .startImmediately(request):
            refetch(request: request)
        }
    }
    
    private func startPollingIfNeeded(for request: Request) {
        switch pollingBehavior {
        case .noPolling:
            break
        case let .pollEvery(interval):
            Timer
                .publish(every: interval, on: .main, in: RunLoop.Mode.default)
                .autoconnect()
                .sink { (_) in
                    self.performFetch(for: request)
                }
                .store(in: &timerCancellables)
        }
    }
    
    private func isCacheValid(for key: QueryKey) -> Bool {
        return self.cache.isValueValid(
            forKey: key,
            timestamp: Date(),
            andInvalidationPolicy: self.cacheConfig.invalidationPolicy
        )
    }
    
    private func getCacheValueIfPossible(for key: QueryKey) -> Response? {
        if isCacheValid(for: key) {
           return self.cache.get(for: key)
        } else {
            return nil
        }
    }
    
    private func performFetch(for request: Request) {
        let key = self.keyAdapter(self.key, request)
        
        if self.cacheConfig.usagePolicy == .useInsteadOfFetching && isCacheValid(for: key) {
            if let value: Response = self.cache.get(for: key) {
                self.state = .succeed(value)
            }
            return
        }
        
        if self.cacheConfig.usagePolicy == .useAndThenFetch
            || self.cacheConfig.usagePolicy == .useAndThenFetchIgnoringFails {
            if let value = getCacheValueIfPossible(for: key) {
                self.state = .succeed(value)
            }
        }
        
        fetcher(request)
            .sink(
                receiveCompletion: { [weak self] (completion: Subscribers.Completion<Error>) in
                    self?.process(completion: completion)
                },
                receiveValue: { [weak self] (response: Response) in
                    self?.set(state: .succeed(response))
                    self?.cache.save(
                        response,
                        for: key,
                        andTimestamp: Date()
                    )
                }
            )
            .store(in: &cancellables)
    }

    private func process(completion: Subscribers.Completion<Error>) {
        switch completion {
        case let .failure(error):
            timerCancellables.forEach({ $0.cancel() })
            if cacheConfig.usagePolicy == .useIfFetchFails ||
                cacheConfig.usagePolicy == .useAndThenFetchIgnoringFails {
                if let value = getCacheValueIfPossible(for: key) {
                    set(state: .succeed(value))
                } else {
                    set(state: .failed(error))
                }
            } else {
                set(state: .failed(error))
            }
        case .finished:
            break
        }
    }

    private func set(state: State) {
        DispatchQueue.main.async {
            self.state = state
        }
    }
}
