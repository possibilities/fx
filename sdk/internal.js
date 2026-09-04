const nativeHostOptions = new WeakSet();

export function authorizeNativeHostOptions(options) {
  nativeHostOptions.add(options);
  return options;
}

export function consumeNativeHostAuthorization(options) {
  return nativeHostOptions.delete(options);
}
