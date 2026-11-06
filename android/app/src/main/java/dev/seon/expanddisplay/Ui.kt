package dev.seon.expanddisplay

import android.annotation.SuppressLint
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.displayCutoutPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView

@Composable
fun AppScreen(controller: AppController) {
    val state by controller.state.collectAsState()
    when (val s = state) {
        is ConnState.Connected -> StreamScreen(controller)
        else -> ConnectScreen(controller, s)
    }
}

@SuppressLint("ClickableViewAccessibility")
@Composable
fun StreamScreen(controller: AppController) {
    val hasVideo by controller.hasVideo.collectAsState()
    val status by controller.status.collectAsState()

    BackHandler { controller.disconnect(userInitiated = true) }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                SurfaceView(ctx).apply {
                    holder.addCallback(object : SurfaceHolder.Callback {
                        override fun surfaceCreated(holder: SurfaceHolder) {}
                        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                            controller.onSurface(holder.surface, width, height)
                        }
                        override fun surfaceDestroyed(holder: SurfaceHolder) {
                            controller.onSurfaceDestroyed()
                        }
                    })
                    setOnTouchListener { v, e ->
                        controller.onTouch(e, v.width, v.height)
                        true
                    }
                }
            },
        )
        if (!hasVideo) {
            Column(
                Modifier.align(Alignment.Center).padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                CircularProgressIndicator()
                Spacer(Modifier.height(16.dp))
                Text(status ?: "Mac 화면을 기다리는 중…", color = Color.White)
                Spacer(Modifier.height(8.dp))
                Text("뒤로 가기: 연결 끊기", color = Color.Gray, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
fun ConnectScreen(controller: AppController, state: ConnState) {
    val hosts by controller.discovery.hosts.collectAsState()
    val auto by controller.autoConnect.collectAsState()
    var manualIp by rememberSaveable { mutableStateOf("") }

    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Box(Modifier.fillMaxSize().systemBarsPadding().displayCutoutPadding(), contentAlignment = Alignment.TopCenter) {
            Column(
                Modifier.widthIn(max = 560.dp).fillMaxWidth().padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("ExpandDisplay", style = MaterialTheme.typography.headlineMedium)
                Text(
                    "Mac에서 ExpandDisplay를 실행하고, 폰과 Mac을 같은 Wi-Fi(또는 폰 핫스팟)에 연결하세요.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )

                when (state) {
                    is ConnState.Connecting -> Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.size(12.dp))
                        Text("${state.host.name}에 연결 중…")
                    }
                    is ConnState.Disconnected -> state.error?.let {
                        Text("⚠ $it", color = MaterialTheme.colorScheme.error)
                    }
                    else -> {}
                }

                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("자동 연결", Modifier.weight(1f))
                    Switch(checked = auto, onCheckedChange = { controller.setAutoConnect(it) })
                }

                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("찾은 Mac", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                    OutlinedButton(onClick = { controller.rescan() }) { Text("다시 찾기") }
                }
                if (hosts.isEmpty()) {
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                    Text("검색 중…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                LazyColumn(
                    Modifier.weight(1f, fill = false),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(hosts, key = { it.name }) { h ->
                        Card(onClick = { controller.connect(h) }, modifier = Modifier.fillMaxWidth()) {
                            Column(Modifier.padding(16.dp)) {
                                Text(h.name, style = MaterialTheme.typography.titleMedium)
                                Text("${h.address}:${h.port}", style = MaterialTheme.typography.bodySmall)
                            }
                        }
                    }
                }

                Text("직접 연결", style = MaterialTheme.typography.titleMedium)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = manualIp,
                        onValueChange = { manualIp = it.trim() },
                        label = { Text("Mac IP (예: 192.168.0.10)") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
                        modifier = Modifier.weight(1f),
                    )
                    Spacer(Modifier.size(8.dp))
                    Button(
                        enabled = manualIp.isNotBlank(),
                        onClick = {
                            val (ip, port) = parseHostPort(manualIp)
                            controller.connect(HostInfo(ip, ip, port))
                        },
                    ) { Text("연결") }
                }
            }
        }
    }
}

private fun parseHostPort(s: String): Pair<String, Int> {
    val idx = s.lastIndexOf(':')
    if (idx > 0 && s.count { it == ':' } == 1) {
        val port = s.substring(idx + 1).toIntOrNull()
        if (port != null) return s.substring(0, idx) to port
    }
    return s to Proto.DEFAULT_PORT
}
