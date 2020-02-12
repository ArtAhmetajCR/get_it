part of 'get_it.dart';

/// Two handy function that helps me to express my intention clearer and shorter to check for runtime
/// errors
void throwIf(bool condition, Object error) {
  if (condition) throw (error);
}

void throwIfNot(bool condition, Object error) {
  if (!condition) throw (error);
}

/// You will see a rather esoteric looking test `(const Object() is! T)` at several places
/// /// it tests if [T] is a real type and not Object or dynamic

/// For each registered factory/singleton a [_ServiceFactory<T>] is created
/// it holds either the instance of a Singleton or/and the creation functions
/// for creating an instance when [get] is called
///
/// There are three different types
enum _ServiceFactoryType {
  alwaysNew,

  /// factory which means on every call of [get] a new instance is created
  constant, // normal singleton
  lazy, // lazy
}

/// If I use `Singleton` without specifier in the comments I mean normal and lazy

class _ServiceFactory<T, P1, P2> {
  final _ServiceFactoryType factoryType;

  Type param1Type;
  Type param2Type;

  /// Because of the different creation methods we need alternative factory functions
  /// only one of them is always set.
  final FactoryFunc<T> creationFunction;
  final FactoryFuncAsync<T> asyncCreationFunction;
  final FactoryFuncParam<T, P1, P2> creationFunctionParam;
  final FactoryFuncParamAsync<T, P1, P2> asyncCreationFunctionParam;

  /// In case of a named registration the instance name is here stored for easy access
  final String instanceName;

  /// true if one of the async registration functions have been used
  final bool isAsync;

  /// If a an existing Object gets registered or an async/lazy Singleton has finished
  /// its creation it is stored here
  Object instance;

  /// the type that was used when registering. used for runtime checks
  Type registrationType;

  /// to enable Singletons to signal that they are ready (their initialization is finished)
  Completer _readyCompleter;

  /// the returned future of pending async factory calls or facttory call with dependencies
  Future<T> pendingResult;

  /// If other objects are waiting for this one
  /// they are stored here
  final List<Type> objectsWaiting = [];

  bool get isReady => _readyCompleter.isCompleted;

  bool get isNamedRegistration => instanceName != null;

  String get debugName =>
      isNamedRegistration ? instanceName : registrationType.toString();

  bool get canBeWaitedFor =>
      shouldSignalReady || pendingResult != null || isAsync;

  final bool shouldSignalReady;

  _ServiceFactory(
    this.factoryType, {
    this.creationFunction,
    this.asyncCreationFunction,
    this.creationFunctionParam,
    this.asyncCreationFunctionParam,
    this.instance,
    this.isAsync = false,
    this.instanceName,
    @required this.shouldSignalReady,
  }) {
    registrationType = T;
    param1Type = P1;
    param2Type = P2;
    _readyCompleter = Completer();
  }

  /// returns an instance depending on the type of the registration if [async==false]
  T getObject(dynamic param1, dynamic param2) {
    assert(
        !(factoryType != _ServiceFactoryType.alwaysNew &&
            (param1 != null || param2 != null)),
        'You can only pass parameters to factories!');

    try {
      switch (factoryType) {
        case _ServiceFactoryType.alwaysNew:
          if (creationFunctionParam != null) {
            assert(
                param1 == null || param1.runtimeType == param1Type,
                'Incompatible Type passed as param1\n'
                'expected: $param1Type actual: ${param1.runtimeType}');
            assert(
                param2 == null || param2.runtimeType == param2Type,
                'Incompatible Type passed as param2\n'
                'expected: $param2Type actual: ${param2.runtimeType}');
            return creationFunctionParam(param1, param2);
          } else {
            return creationFunction();
          }
          break;
        case _ServiceFactoryType.constant:
          return instance as T;
          break;
        case _ServiceFactoryType.lazy:
          if (instance == null) {
            instance = creationFunction();
            _readyCompleter.complete();
          }
          return instance as T;
          break;
        default:
          throw (StateError('Impossible factoryType'));
      }
    } catch (e, s) {
      print("Error while creating ${T.toString()}");
      print('Stack trace:\n $s');
      rethrow;
    }
  }

  /// returns an async instance depending on the type of the registration if [async==true] or if [dependsOn.isnoEmpty].
  Future<T> getObjectAsync(dynamic param1, dynamic param2) async {
    assert(
        !(factoryType != _ServiceFactoryType.alwaysNew &&
            (param1 != null || param2 != null)),
        'You can only pass parameters to factories!');

    throwIfNot(
        isAsync || pendingResult != null,
        StateError(
            'You can only access registered factories/objects this way if they are created asynchronously'));
    try {
      switch (factoryType) {
        case _ServiceFactoryType.alwaysNew:
          if (asyncCreationFunctionParam != null) {
            assert(
                param1 == null || param1.runtimeType == param1Type,
                'Incompatible Type passed a param1\n'
                'expected: $param1Type actual: ${param1.runtimeType}');
            assert(
                param2 == null || param2.runtimeType == param2Type,
                'Incompatible Type passed a param2\n'
                'expected: $param2Type actual: ${param2.runtimeType}');
            return asyncCreationFunctionParam(param1, param2);
          } else {
            return asyncCreationFunction();
          }
          break;
        case _ServiceFactoryType.constant:
          if (instance != null) {
            return Future<T>.value(instance);
          } else {
            assert(pendingResult != null);
            return pendingResult;
          }
          break;
        case _ServiceFactoryType.lazy:
          if (instance != null) {
            // We already have a finished instance
            return Future<T>.value(instance);
          } else {
            if (pendingResult !=
                null) // an async creation is already in progress
            {
              return pendingResult;
            }

            /// Seems this is really the first access to this async Signleton
            Future<T> asyncResult = asyncCreationFunction();

            pendingResult = (asyncResult).then((newInstance) {
              if (!shouldSignalReady) {
                ///only complete automatically if the registration wasn't marked with [signalsReady==true]
                _readyCompleter.complete();
              }
              instance = newInstance;
              return newInstance;
            });
            return pendingResult;
          }
          break;
        default:
          throw (StateError('Impossible factoryType'));
      }
    } catch (e, s) {
      print("Error while creating ${T.toString()}");
      print('Stack trace:\n $s');
      rethrow;
    }
  }
}

class _GetItImplementation implements GetIt {
  /// stores all [_ServiceFactory] that get registered by Type
  final _factories = Map<Type, _ServiceFactory<dynamic, dynamic, dynamic>>();

  /// the ones that get registered by name.
  final _factoriesByName =
      Map<String, _ServiceFactory<dynamic, dynamic, dynamic>>();

  /// We still support a global ready signal mechanism for that we use this
  /// Completer.
  final _globalReadyCompleter = Completer();

  /// By default it's not allowed to register a type a second time.
  /// If you really need to you can disable the asserts by setting[allowReassignment]= true
  @override
  bool allowReassignment = false;

  /// Is used by several other functions to retrieve the correct [_ServiceFactory]
  _ServiceFactory _findFactoryByNameOrType<T>(String instanceName) {
    /// We use an assert here instead of an `if..throw` because it gets called on every call
    /// of [get]
    /// `(const Object() is! T)` tests if [T] is a real type and not Object or dynamic
    assert(
      !(!(const Object() is! T) && (instanceName == null)),
      'GetIt: You have to provide either a type or a name. Did you accidentally do  `var sl=GetIt.instance();` instead of var sl=GetIt.instance;',
    );

    _ServiceFactory<T, dynamic, dynamic> instanceFactory;
    if (instanceName != null) {
      instanceFactory = _factoriesByName[instanceName];
      assert(instanceFactory != null,
          "Object/factory with name $instanceName is not registered inside GetIt");
    } else {
      instanceFactory = _factories[T];
      assert(instanceFactory != null,
          "No type ${T.toString()} is registered inside GetIt.\n Did you forget to pass an instance name? \n(Did you accidentally do  GetIt sl=GetIt.instance(); instead of GetIt sl=GetIt.instance;)");
    }
    return instanceFactory;
  }

  /// retrieves or creates an instance of a registered type [T] depending
  /// on if the registration function used for this type or based on a name.
  @override
  T get<T>({String instanceName, dynamic param1, dynamic param2}) {
    var instanceFactory = _findFactoryByNameOrType<T>(instanceName);

    Object instance;
    if (instanceFactory.isAsync || instanceFactory.pendingResult != null) {
      /// We use an assert here instead of an `if..throw` for performance reasons
      assert(
          instanceFactory.factoryType == _ServiceFactoryType.constant ||
              instanceFactory.factoryType == _ServiceFactoryType.lazy,
          "You can't use get with an async Factory of ${instanceName != null ? instanceName : T.toString()}.");
      assert(instanceFactory.isReady,
          'You tried to access an instance of ${instanceName != null ? instanceName : T.toString()} that was not ready yet');
      instance = instanceFactory.instance;
    } else {
      instance = instanceFactory.getObject(param1, param2);
    }

    assert(instance is T,
        "Object with name $instanceName has a different type (${instanceFactory.registrationType.toString()}) than the one that is inferred (${T.toString()}) where you call it");

    return instance;
  }

  /// Callable class so that you can write `GetIt.instance<MyType>` instead of
  /// `GetIt.instance.get<MyType>`
  T call<T>({String instanceName, dynamic param1, dynamic param2}) {
    return get<T>(instanceName: instanceName,param1: param1,param2: param2);
  }

  /// Returns an Future of an instance that may not be ready yet
  @override
  Future<T> getAsync<T>({String instanceName, dynamic param1, dynamic param2}) {
    final factoryToGet = _findFactoryByNameOrType<T>(instanceName);
    return factoryToGet.getObjectAsync(param1, param2);
  }

  /// registers a type so that a new instance will be created on each call of [get] on that type
  /// [T] type to register
  /// [func] factory function for this type
  /// [instanceName] if you provide a value here your factory gets registered with that
  /// name instead of a type. This should only be necessary if you need to register more
  /// than one instance of one type. Its highly not recommended
  @override
  void registerFactory<T>(FactoryFunc<T> func, {String instanceName}) {
    _register<T, void, void>(
        type: _ServiceFactoryType.alwaysNew,
        instanceName: instanceName,
        factoryFunc: func,
        isAsync: false,
        shouldSignalReady: false);
  }

  @override
  void registerFactoryParam<T, P1, P2>(FactoryFuncParam<T, P1, P2> func,
      {String instanceName}) {
    _register<T, P1, P2>(
        type: _ServiceFactoryType.alwaysNew,
        instanceName: instanceName,
        factoryFuncParam: func,
        isAsync: false,
        shouldSignalReady: false);
  }

  /// We use a separate function for the async registration instead just a new parameter
  /// so make the intention explicit
  @override
  void registerFactoryAsync<T>(FactoryFuncAsync<T> asyncFunc,
      {String instanceName}) {
    _register<T, void, void>(
        type: _ServiceFactoryType.alwaysNew,
        instanceName: instanceName,
        factoryFuncAsync: asyncFunc,
        isAsync: true,
        shouldSignalReady: false);
  }

  @override
  void registerFactoryParamAsync<T, P1, P2>(
      FactoryFuncParamAsync<T, P1, P2> func,
      {String instanceName}) {
    _register<T, P1, P2>(
        type: _ServiceFactoryType.alwaysNew,
        instanceName: instanceName,
        factoryFuncParamAsync: func,
        isAsync: true,
        shouldSignalReady: false);
  }

  /// registers a type as Singleton by passing a factory function that will be called on the first call of [get] on that type
  /// [T] type to register
  /// [func] factory function for this type
  /// [instanceName] if you provide a value here your factory gets registered with that
  /// name instead of a type. This should only be necessary if you need to register more
  /// than one instance of one type. Its highly not recommended
  /// If [signalsReady] is set to `true` it means that the future you can get from `allReady()`  cannot complete until this
  /// registration was signalled ready by calling [signalsReady(instance)]
  @override
  void registerLazySingleton<T>(FactoryFunc<T> func,
      {String instanceName, bool signalsReady = false}) {
    _register<T, void, void>(
        type: _ServiceFactoryType.lazy,
        instanceName: instanceName,
        factoryFunc: func,
        isAsync: signalsReady,
        shouldSignalReady: signalsReady);
  }

  /// registers a type as Singleton by passing an [instance] of that type
  ///  that will be returned on each call of [get] on that type
  /// [T] type to register
  /// If [signalsReady] is set to `true` it means that the future you can get from `allReady()`  cannot complete until this
  /// registration was signalled ready by calling [signalsReady(instance)]
  /// [instanceName] if you provide a value here your instance gets registered with that
  /// name instead of a type. This should only be necessary if you need to register more
  /// than one instance of one type. Its highly not recommended
  @override
  void registerSingleton<T>(
    T instance, {
    String instanceName,
    bool signalsReady = false,
  }) {
    _register<T, void, void>(
        type: _ServiceFactoryType.constant,
        instanceName: instanceName,
        instance: instance,
        isAsync: false,
        shouldSignalReady: signalsReady);
  }

  @override
  void registerSingletonWithDependencies<T>(
    FactoryFunc<T> providerFunc, {
    String instanceName,
    Iterable<Type> dependsOn,
    bool signalsReady = false,
  }) {
    _register<T, void, void>(
        type: _ServiceFactoryType.constant,
        instanceName: instanceName,
        isAsync: false,
        factoryFunc: providerFunc,
        dependsOn: dependsOn,
        shouldSignalReady: signalsReady);
  }

  @override
  void registerSingletonAsync<T>(FactoryFuncAsync<T> providerFunc,
      {String instanceName,
      Iterable<Type> dependsOn,
      bool signalsReady = false}) {
    _register<T, void, void>(
        type: _ServiceFactoryType.constant,
        instanceName: instanceName,
        isAsync: true,
        factoryFuncAsync: providerFunc,
        dependsOn: dependsOn,
        shouldSignalReady: signalsReady);
  }

  @override
  void registerLazySingletonAsync<T>(FactoryFuncAsync<T> func,
      {String instanceName, bool signalsReady = false}) {
    _register<T, void, void>(
        isAsync: true,
        type: _ServiceFactoryType.lazy,
        instanceName: instanceName,
        factoryFuncAsync: func,
        shouldSignalReady: signalsReady);
  }

  /// Clears all registered types. Handy when writing unit tests
  @override
  void reset() {
    _factories.clear();
    _factoriesByName.clear();
  }

  void _register<T, P1, P2>({
    @required _ServiceFactoryType type,
    FactoryFunc<T> factoryFunc,
    FactoryFuncParam<T, P1, P2> factoryFuncParam,
    FactoryFuncAsync<T> factoryFuncAsync,
    FactoryFuncParamAsync<T, P1, P2> factoryFuncParamAsync,
    T instance,
    @required String instanceName,
    @required bool isAsync,
    Iterable<Type> dependsOn,
    @required bool shouldSignalReady,
  }) {
    print(T.toString());

    throwIf(
      (!(const Object() is! T) && (instanceName == null)),
      'GetIt: You have to provide either a type or a name. Did you accidentally do  `var sl=GetIt.instance();` instead of var sl=GetIt.instance;',
    );

    throwIf(
      (instanceName != null &&
          (_factoriesByName.containsKey(instanceName) && !allowReassignment)),
      ArgumentError("An object of name $instanceName is already registered"),
    );
    throwIf(
        (instanceName == null &&
            _factories.containsKey(T) &&
            !allowReassignment),
        ArgumentError("Type ${T.toString()} is already registered"));

    final serviceFactory = _ServiceFactory<T, P1, P2>(
      type,
      creationFunction: factoryFunc,
      creationFunctionParam: factoryFuncParam,
      asyncCreationFunctionParam: factoryFuncParamAsync,
      asyncCreationFunction: factoryFuncAsync,
      instance: instance,
      isAsync: isAsync,
      instanceName: instanceName,
      shouldSignalReady: shouldSignalReady,
    );

    if (instanceName == null) {
      _factories[T] = serviceFactory;
    } else {
      _factoriesByName[instanceName] = serviceFactory;
    }

    // simple Singletons get creates immediately
    if (type == _ServiceFactoryType.constant &&
        !shouldSignalReady &&
        !isAsync &&
        (dependsOn?.isEmpty ?? false)) {
      serviceFactory.instance = factoryFunc();
      serviceFactory._readyCompleter.complete();
      return;
    }

    // if its an async or an dependent Singleton we start its creation function here after we check if
    // it is dependent on other registered Singletons.
    if ((isAsync || (dependsOn?.isNotEmpty ?? false)) &&
        type == _ServiceFactoryType.constant) {
      /// Any client awaiting the completion of this Singleton
      /// Has to wait for the completion of the Singleton itself as well
      /// as for the completion of all the Singletons this one depends on
      /// For this we use [outerFutureGroup]
      /// A `FutureGroup` completes only if it's closed and all contained
      /// Futures have completed
      FutureGroup outerFutureGroup = FutureGroup();
      Future dependentFuture;

      if (dependsOn?.isNotEmpty ?? false) {
        /// To wait for the completion of all Singletons this one is depending on
        /// before we start to create itself we use [dependentFutureGroup]
        var dependentFutureGroup = FutureGroup();

        dependsOn.forEach((type) {
          var dependentFactory = _factories[type];
          throwIf(dependentFactory == null,
              ArgumentError('Dependent Type $type is not registered in GetIt'));
          throwIfNot(dependentFactory.canBeWaitedFor,
              ArgumentError('Dependent Type $type is an async Singleton'));
          dependentFactory.objectsWaiting.add(serviceFactory.registrationType);
          dependentFutureGroup.add(dependentFactory._readyCompleter.future);
        });
        dependentFutureGroup.close();

        dependentFuture = dependentFutureGroup.future;
      } else {
        /// if we have no dependencies we still create a dummy Future so that
        /// we can use the same code path further down
        dependentFuture = Future.sync(() {}); // directly execute then
      }
      outerFutureGroup.add(dependentFuture);

      /// if someone uses getAsync on an async Singleton that has not be started to get created
      /// because its dependent on other objects this doesn't work because [pendingResult] is not set in
      /// that case. Therefore we have to set [outerFutureGroup] as [pendingResult]
      dependentFuture.then((_) {
        Future<T> isReadyFuture;
        if (!isAsync) {
          /// SingletonWithDepencencies
          serviceFactory.instance = factoryFunc();
          isReadyFuture = Future.value(serviceFactory.instance);
          if (!serviceFactory.shouldSignalReady) {
            /// As this isn't an asnc function we declare it as ready here
            /// if is wasn't marked that it will signalReady
            serviceFactory._readyCompleter.complete();
          }
        } else {
          /// Async Singleton with dependencies
          final asyncResult = factoryFuncAsync();

          isReadyFuture = asyncResult.then((instance) {
            serviceFactory.instance = instance;

            if (!serviceFactory.shouldSignalReady && !serviceFactory.isReady) {
              serviceFactory._readyCompleter.complete();
            }
            return instance;
          });
        }
        outerFutureGroup.add(isReadyFuture);
        outerFutureGroup.close();
      });

      /// outerFutureGroup.future returns a Future<List> and not a Future<T>
      /// As we know that the actual factory function was added last to the FutureGroup
      /// we just use that one
      serviceFactory.pendingResult =
          outerFutureGroup.future.then((completedFutures) {
        return completedFutures.last;
      });
    }
  }

  @override
  bool isRegistered<T>({Object instance, String instanceName}) {
    _ServiceFactory factoryToCheck;
    try {
      if (instance != null) {
        factoryToCheck = _findFactoryByInstance(instance);
      } else {
        factoryToCheck = _findFactoryByNameOrType<T>(instanceName);
      }
    } on StateError {
      return false;
    } on AssertionError {
      return false;
    }
    return factoryToCheck != null;
  }

  /// Unregister an instance of an object or a factory/singleton by Type [T] or by name [instanceName]
  /// if you need to dispose any resources you can do it using [disposingFunction] function
  /// that provides a instance of your class to be disposed
  @override
  void unregister<T>(
      {Object instance,
      String instanceName,
      void Function(T) disposingFunction}) {
    _ServiceFactory factoryToRemove;
    if (instance != null) {
      factoryToRemove = _findFactoryByInstance(instance);
    } else {
      factoryToRemove = _findFactoryByNameOrType<T>(instanceName);
    }

    throwIf(
        factoryToRemove.objectsWaiting.isNotEmpty,
        StateError(
            'There are still other objects waiting for this instance so signal ready'));

    if (factoryToRemove.isNamedRegistration) {
      _factoriesByName.remove(factoryToRemove.instanceName);
    } else {
      _factories.remove(factoryToRemove.registrationType);
    }

    if (factoryToRemove.instance != null) {
      disposingFunction?.call(factoryToRemove.instance);
    }
  }

  /// Clears the instance of a lazy singleton registered type, to be able
  /// to call the factory function on that type again.
  @override
  void resetLazySingleton<T>(
      {Object instance,
      String instanceName,
      void Function(T) disposingFunction}) {
    _ServiceFactory instanceFactory;

    if (instance != null) {
      instanceFactory = _findFactoryByInstance(instance);
    } else {
      instanceFactory = _findFactoryByNameOrType<T>(instanceName);
    }
    throwIfNot(
        instanceFactory.factoryType == _ServiceFactoryType.lazy,
        StateError(
            'There is no type ${instance.runtimeType} registered as LazySingleton in GetIt'));
    instanceFactory.instance = null;
    instanceFactory.pendingResult == null;
    instanceFactory._readyCompleter = Completer();

    if (instanceFactory.instance != null) {
      disposingFunction?.call(instanceFactory.instance);
    }
  }

  _ServiceFactory _findFactoryByInstance(Object instance) {
    var registeredFactories = _factories.values
        .followedBy(_factoriesByName.values)
        .where((x) => identical(x.instance, instance));

    throwIf(
        registeredFactories.isEmpty,
        StateError(
            'There is no object type ${instance.runtimeType} registered in GetIt'));

    throwIfNot(
        registeredFactories.length == 1,
        StateError(
            'One Instance of ${instance.runtimeType} more than once registered in GetIt'));
    return registeredFactories.first;
  }

  /// if [instance] is `null` and no factory/singleton is waiting to be signaled this will complete the future you got
  /// from [allReady]
  ///
  /// If [instance] has a value GetIt will search for the responsible factory/singleton and complete all futures you might
  /// have received by calling [isReady]
  /// Typically this is use in this way inside the registered objects init method `GetIt.instance.signalReady(this);`
  /// If all waiting singletons/factories have signaled ready the future you can get from [allReady] is automatically completed
  ///
  /// Both ways are mutual exclusive meaning either only use the global `signalReady()` and don't register a singlton/fatory as signaling ready
  /// Or let indiviual instance signal their ready state on their own.
  @override
  void signalReady(Object instance) {
    _ServiceFactory registeredInstance;
    if (instance != null) {
      registeredInstance = _findFactoryByInstance(instance);
      throwIf(
          registeredInstance == null,
          ArgumentError.value(instance,
              'There is no object type ${instance.runtimeType} registered in GetIt'));

      throwIfNot(
          registeredInstance.shouldSignalReady,
          ArgumentError.value(instance,
              'This instance of type ${instance.runtimeType} is not supposed to be signalled.\nDid you forget to set signalsReady==true when registering it?'));

      throwIf(
          registeredInstance.isReady,
          StateError(
              'This instance of type ${instance.runtimeType} was already signalled'));

      registeredInstance._readyCompleter.complete();
      registeredInstance.objectsWaiting.clear();
    } else {
      /// Manual signalReady without an instance

      /// In case that there are still factories that are marked to wait for a signal
      /// but aren't signalled we throw an error with details which objects are concerned
      final notReadyTypes = _factories.entries
          .where((x) =>
              (x.value.shouldSignalReady) && (!x.value.isReady) ||
              (x.value.pendingResult != null) && (!x.value.isReady))
          .map<String>((x) => x.key.toString())
          .toList();
      final notReadyNames = _factoriesByName.entries
          .where((x) => x.value.canBeWaitedFor && !x.value.isReady)
          .map<String>((x) => x.key)
          .toList();
      throwIf(
          notReadyNames.isNotEmpty || notReadyTypes.isNotEmpty,
          StateError(
              'You can\'t signal reads manually if you have registered instances that should signal ready or are asnyc.\n'
              'Did you forget to pass an object instance?'
              'This registered types/names: $notReadyTypes  / $notReadyNames should signal ready but are not ready'));

      _globalReadyCompleter.complete();
    }
  }

  /// returns a Future that completes if all asynchronously created Singletons are ready
  /// This can be used inside a FutureBuilder to change the UI as soon as all initialization
  /// is done
  /// If you pass a [timeout], an [WaitingTimeOutException] will be thrown if not all Singletons
  /// were ready in the given time. The Exception contains details on which Singletons are not ready yet.
  @override
  Future<void> allReady(
      {Duration timeout, ignorePendingAsyncCreation = false}) {
    FutureGroup futures = FutureGroup();
    _factories.values
        .followedBy(_factoriesByName.values)
        .where((x) => ((x.isAsync && !ignorePendingAsyncCreation ||
                    (!x.isAsync &&
                        x.pendingResult !=
                            null) || // Singletons with dependencies
                    x.shouldSignalReady) &&
                !x.isReady &&
                x.factoryType == _ServiceFactoryType.constant ||
            x.factoryType == _ServiceFactoryType.lazy))
        .forEach((f) {
      futures.add(f._readyCompleter.future);
    });
    futures.close();
    if (timeout != null) {
      return futures.future.timeout(timeout, onTimeout: _throwTimeoutError);
    } else {
      return futures.future;
    }
  }

  /// Returns if all async Singletons are ready without waiting
  @override
  bool allReadySync([ignorePendingAsyncCreation = false]) {
    final notReadyTypes = _factories.values
        .followedBy(_factoriesByName.values)
        .where((x) => ((x.isAsync && !ignorePendingAsyncCreation ||
                    (!x.isAsync &&
                        x.pendingResult !=
                            null) || // Singletons with dependencies
                    x.shouldSignalReady) &&
                !x.isReady &&
                x.factoryType == _ServiceFactoryType.constant ||
            x.factoryType == _ServiceFactoryType.lazy))
        .map<String>((x) {
      if (x.isNamedRegistration) {
        return 'Object ${x.instanceName} has not completed';
      } else {
        return 'Registered object of Type ${x.registrationType.toString()} has not completed';
      }
    }).toList();

    /// IN debug mode we print the List of not ready types/named instances
    if (notReadyTypes.isNotEmpty) {
      // Hack to only output this in debug mode;
      assert(() {
        print('Not yet ready objects:');
        print(notReadyTypes);
        return true;
      }());
    }
    return notReadyTypes.isEmpty;
  }

  List<dynamic> _throwTimeoutError() {
    final allFactories = _factories.values.followedBy(_factoriesByName.values);
    final waitedBy = Map.fromEntries(
      allFactories
          .where((x) =>
              (x.shouldSignalReady || x.pendingResult != null) &&
              !x.isReady &&
              x.objectsWaiting.isNotEmpty)
          .map<MapEntry<String, List<String>>>(
            (isWaitedFor) => MapEntry(
                isWaitedFor.debugName,
                isWaitedFor.objectsWaiting
                    .map((waitedByType) => waitedByType.toString())
                    .toList()),
          ),
    );
    final notReady = allFactories
        .where((x) =>
            (x.shouldSignalReady || x.pendingResult != null) && !x.isReady)
        .map((f) => f.debugName)
        .toList();
    final areReady = allFactories
        .where((x) =>
            (x.shouldSignalReady || x.pendingResult != null) && x.isReady)
        .map((f) => f.debugName)
        .toList();

    throw WaitingTimeOutException(waitedBy, notReady, areReady);
  }

  /// Returns a Future that completes if an instance of an Singleton defined by Type [T] or by name [instanceName]
  /// or by passing the an existing [instance]  is ready
  /// This can be used inside a FutureBuilder to change the UI as soon as all initialization
  /// is done
  /// If you pass a [timeout], an [WaitingTimeOutException] will be thrown if not all Singletons
  /// were ready in the given time. The Exception contains details on which Singletons are not ready yet.
  @override
  Future<void> isReady<T>({
    Object instance,
    String instanceName,
    Duration timeout,
    Object callee,
  }) {
    _ServiceFactory factoryToCheck;
    if (instance != null) {
      factoryToCheck = _findFactoryByInstance(instance);
    } else {
      factoryToCheck = _findFactoryByNameOrType<T>(instanceName);
    }
    throwIfNot(
      factoryToCheck.canBeWaitedFor &&
          factoryToCheck.registrationType != _ServiceFactoryType.alwaysNew,
      ArgumentError(
          'You only can use this function on Singletons that are async, that are marked as dependen '
          'or that are marked with "signalsReady==true"'),
    );
    factoryToCheck.objectsWaiting.add(callee.runtimeType);
    if (timeout != null) {
      return factoryToCheck._readyCompleter.future
          .timeout(timeout, onTimeout: _throwTimeoutError);
    } else {
      return factoryToCheck._readyCompleter.future;
    }
  }

  /// Checks if an async Singleton defined by an [instance], a type [T] or an [instanceName]
  /// is ready without waiting.
  @override
  bool isReadySync<T>({Object instance, String instanceName}) {
    _ServiceFactory factoryToCheck;
    if (instance != null) {
      factoryToCheck = _findFactoryByInstance(instance);
    } else {
      factoryToCheck = _findFactoryByNameOrType<T>(instanceName);
    }
    throwIfNot(
        factoryToCheck.canBeWaitedFor &&
            factoryToCheck.registrationType != _ServiceFactoryType.alwaysNew,
        ArgumentError(
            'You only can use this function on async Singletons or Singletons '
            'that have ben marked with "signalsReady" or that they depend on others'));
    return factoryToCheck.isReady;
  }
}
