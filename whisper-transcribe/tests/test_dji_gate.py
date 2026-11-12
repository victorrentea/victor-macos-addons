"""The DJI receiver is a source only while a transmitter is linked (2026-11-12).

With only the receiver plugged in, CoreAudio lists `Wireless Mic Rx` as a live
input and the ladder (XLR ▸ DJI ▸ …) used to pick it, then transcribe digital
zeros. The app writes the receiver's own link state to WHISPER_DJI_GATE_FILE.
"""
import whisper_runner as wr


DJI = "Wireless Mic Rx"


def _gate(monkeypatch, tmp_path, word):
    f = tmp_path / ".dji-source-gate"
    if word is not None:
        f.write_text(word)
    monkeypatch.setattr(wr, "_DJI_GATE_FILE", str(f))


def test_no_tx_blocks_the_dji(monkeypatch, tmp_path):
    for word in ("no-tx", "absent"):
        _gate(monkeypatch, tmp_path, word)
        assert wr._is_unusable(DJI), word


def test_linked_or_blind_lets_it_in(monkeypatch, tmp_path):
    for word in ("linked", "blind"):
        _gate(monkeypatch, tmp_path, word)
        assert not wr._is_unusable(DJI), word


def test_no_gate_is_the_old_behaviour(monkeypatch, tmp_path):
    _gate(monkeypatch, tmp_path, None)          # env set, file not written yet
    assert not wr._is_unusable(DJI)
    monkeypatch.setattr(wr, "_DJI_GATE_FILE", "")  # env not set at all
    assert not wr._is_unusable(DJI)


def test_the_gate_touches_only_the_dji(monkeypatch, tmp_path):
    _gate(monkeypatch, tmp_path, "no-tx")
    assert not wr._is_unusable("Elgato Wave XLR")
    assert not wr._is_unusable("MacBook Pro Microphone")
    assert wr._is_unusable("WH-1000XM3"), "the never-record list still applies"


def test_the_ladder_skips_a_dji_with_no_tx(monkeypatch, tmp_path):
    import sounddevice as sd

    devices = [
        {"name": DJI, "max_input_channels": 1},
        {"name": "MacBook Pro Microphone", "max_input_channels": 1},
    ]
    monkeypatch.setattr(sd, "query_devices", lambda: devices)
    monkeypatch.setattr(wr, "list_input_devices",
                        lambda: [{"name": d["name"], "alive": True} for d in devices])
    monkeypatch.setattr(wr, "_read_preferred_source", lambda: "Wireless Mic")  # picked by hand, too

    _gate(monkeypatch, tmp_path, "no-tx")
    assert wr._resolve_device_coreaudio(wr._ME_PATTERNS) == (1, "MacBook Pro Microphone")
    assert "🎤" not in wr._available_me_short_names()

    _gate(monkeypatch, tmp_path, "linked")
    assert wr._resolve_device_coreaudio(wr._ME_PATTERNS) == (0, DJI)
    assert wr._available_me_short_names()[0] == "🎤"
