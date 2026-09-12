"""app-server 事件的根轮/协作子轮归属判定，供实时桥和离线摘要共用。"""
from __future__ import annotations


def event_ids(event):
    params = event.get("params") or {}
    thread = params.get("threadId")
    if not thread and isinstance(params.get("thread"), dict):
        thread = params["thread"].get("id")
    turn = params.get("turnId")
    if not turn and isinstance(params.get("turn"), dict):
        turn = params["turn"].get("id")
    return thread, turn


class TurnIdentity:
    def __init__(self, root_thread=None, root_turn=None):
        self.root_thread = root_thread
        self.root_turn = root_turn
        self.children = {}  # thread id -> {turn, label}

    def bind_root(self, thread_id, turn_id):
        self.root_thread = thread_id or self.root_thread
        self.root_turn = turn_id or self.root_turn

    def scope(self, event):
        thread, turn = event_ids(event)
        if thread == self.root_thread:
            return "root" if not turn or not self.root_turn or turn == self.root_turn else "foreign"
        child = self.children.get(thread)
        if child:
            tracked = child.get("turn")
            return "child" if not turn or not tracked or turn == tracked else "foreign"
        return "foreign"

    def register_collaboration(self, event):
        if self.scope(event) != "root":
            return
        item = (event.get("params") or {}).get("item") or {}
        if item.get("type") != "collabAgentToolCall":
            return
        for thread_id in item.get("receiverThreadIds") or []:
            if thread_id not in self.children:
                self.children[thread_id] = {"turn": None, "label": f"subagent-{len(self.children) + 1}"}

    def observe_child_turn(self, event):
        thread, turn = event_ids(event)
        if thread in self.children and turn:
            self.children[thread]["turn"] = turn

    def child_label(self, event):
        thread, _ = event_ids(event)
        return (self.children.get(thread) or {}).get("label")
