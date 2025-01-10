from typing import Callable, Dict, List

class HookManager(object):
    __slots__ = '_hooks'
    def __init__(self):
        self._hooks: Dict[str, List[Callable[..., None]]] = {}

    def register(self, hook_name: str, callback: Callable[..., None]):
        if hook_name not in self._hooks:
            self._hooks[hook_name] = []
        self._hooks[hook_name].append(callback)

    def trigger(self, hook_name: str, *args, **kwargs):
        if hook_name in self._hooks:
            for callback in self._hooks[hook_name]:
                callback(*args, **kwargs)
