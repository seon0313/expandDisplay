package dev.seon.expanddisplay.touchlink

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * TouchLink §4 sender rules: coalesce to ≤ rateHz, STATIONARY keep-alive every 100 ms,
 * ENDED/CANCELLED sent exactly once, BEGAN/ENDED/CANCELLED never dropped. Main thread only.
 */
class TouchFrameSender(private val emit: (ByteArray) -> Unit) {
    private class Slot(val cid: Int) {
        var x = 0
        var y = 0
        var phase = TL.BEGAN
        var pressure = 0
        var radius = 0
    }

    private val slots = LinkedHashMap<Int, Slot>() // pointerId -> slot
    private val handler = Handler(Looper.getMainLooper())
    var rateHz = 120
    private var lastSentMs = 0L
    private var flushPending = false

    // Active area (letterboxed to the Mac display's aspect ratio), in view pixels.
    private var ax = 0f
    private var ay = 0f
    private var aw = 1f
    private var ah = 1f
    private var mmPerPx = 0f

    private val flushRunnable = Runnable { flushPending = false; flush() }
    private val keepAlive = Runnable { if (slots.isNotEmpty()) flush() }

    /** §5: letterbox the Mac display (dw:dh) inside the view. */
    fun setActiveArea(viewW: Int, viewH: Int, displayW: Int?, displayH: Int?, xdpi: Float) {
        if (viewW <= 0 || viewH <= 0) return
        mmPerPx = if (xdpi > 0) 25.4f / xdpi else 0f
        if (displayW == null || displayH == null || displayW <= 0 || displayH <= 0) {
            ax = 0f; ay = 0f; aw = viewW.toFloat(); ah = viewH.toFloat()
            return
        }
        val viewAspect = viewW.toFloat() / viewH
        val dispAspect = displayW.toFloat() / displayH
        if (viewAspect > dispAspect) {
            ah = viewH.toFloat(); aw = ah * dispAspect; ax = (viewW - aw) / 2f; ay = 0f
        } else {
            aw = viewW.toFloat(); ah = aw / dispAspect; ax = 0f; ay = (viewH - ah) / 2f
        }
    }

    private fun nx(x: Float) = (((x - ax) / aw).coerceIn(0f, 1f) * 65535f).toInt()
    private fun ny(y: Float) = (((y - ay) / ah).coerceIn(0f, 1f) * 65535f).toInt()

    private fun freeCid(): Int? {
        val used = slots.values.mapTo(HashSet()) { it.cid }
        return (0..9).firstOrNull { it !in used }
    }

    fun onTouch(e: MotionEvent) {
        val idx = e.actionIndex
        var urgent = false
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                val pid = e.getPointerId(idx)
                if (slots[pid] == null) freeCid()?.let { slots[pid] = Slot(it) }
                urgent = true
            }
        }
        // Positions for every pointer.
        for (i in 0 until e.pointerCount) {
            val s = slots[e.getPointerId(i)] ?: continue
            val x = nx(e.getX(i))
            val y = ny(e.getY(i))
            if (x != s.x || y != s.y) {
                s.x = x
                s.y = y
                if (s.phase == TL.STATIONARY) s.phase = TL.MOVED
            }
            s.pressure = (e.getPressure(i).coerceIn(0f, 1f) * 255f).toInt()
            s.radius = if (mmPerPx > 0) ((e.getTouchMajor(i) / 2f) * mmPerPx * 4f).toInt().coerceIn(0, 255) else 0
        }
        when (e.actionMasked) {
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                slots[e.getPointerId(idx)]?.phase = TL.ENDED
                urgent = true
            }
            MotionEvent.ACTION_CANCEL -> {
                slots.values.forEach { it.phase = TL.CANCELLED }
                urgent = true
            }
        }
        schedule(urgent)
    }

    /** §4 rule 4: OS cancel / app backgrounded. */
    fun cancelAll() {
        if (slots.isEmpty()) return
        slots.values.forEach { it.phase = TL.CANCELLED }
        flush()
    }

    private fun schedule(urgent: Boolean) {
        val now = SystemClock.uptimeMillis()
        val interval = 1000L / rateHz.coerceIn(1, 1000)
        if (urgent || now - lastSentMs >= interval) {
            flush()
        } else if (!flushPending) {
            flushPending = true
            handler.postAtTime(flushRunnable, lastSentMs + interval)
        }
    }

    private fun flush() {
        handler.removeCallbacks(flushRunnable)
        flushPending = false
        handler.removeCallbacks(keepAlive)
        if (slots.isEmpty()) return
        val list = slots.values.toList()
        val b = ByteBuffer.allocate(2 + 8 * list.size).order(ByteOrder.LITTLE_ENDIAN)
        b.put(list.size.toByte()).put(0)
        for (s in list) {
            b.put(s.cid.toByte()).put(s.phase.toByte())
                .putShort(s.x.toShort()).putShort(s.y.toShort())
                .put(s.pressure.toByte()).put(s.radius.toByte())
        }
        emit(b.array())
        lastSentMs = SystemClock.uptimeMillis()
        // ENDED/CANCELLED go out once, then the contact is gone; the rest become STATIONARY.
        val it = slots.entries.iterator()
        while (it.hasNext()) {
            val s = it.next().value
            if (s.phase == TL.ENDED || s.phase == TL.CANCELLED) it.remove() else s.phase = TL.STATIONARY
        }
        if (slots.isNotEmpty()) handler.postDelayed(keepAlive, 100)
    }
}
