package com.mateobenaa1.mdobe

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

/// Prueba: ¿podemos guardar encima de un PDF abierto desde OneDrive?
class MainActivity : ComponentActivity() {
    private var testUri: Uri? = null
    private var report by mutableStateOf("Abre un PDF desde la app de OneDrive con «Abrir con → MDobe», o pulsa el botón.")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handle(intent)
        setContent {
            val ctx = LocalContext.current
            val scheme = if (isSystemInDarkTheme()) dynamicDarkColorScheme(ctx) else dynamicLightColorScheme(ctx)
            val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let { check(it, "selector de archivos") } }
            MaterialTheme(colorScheme = scheme) {
                Surface(Modifier.fillMaxSize()) {
                    Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        Text("MDobe · prueba de guardado", style = MaterialTheme.typography.headlineSmall)
                        Text(report)
                        Button(onClick = { pick.launch(arrayOf("application/pdf")) }) { Text("Elegir PDF") }
                        Button(onClick = { writeTest() }) { Text("Guardar de verdad (solo MDobe-prueba.pdf)") }
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        val uri = intent?.data ?: return
        if (intent.action == Intent.ACTION_VIEW || intent.action == Intent.ACTION_EDIT) check(uri, if (intent.action == Intent.ACTION_EDIT) "Abrir con (EDIT)" else "Abrir con (VIEW)")
    }

    /// Reescribe el PDF de prueba con una línea de comentario más al final (sigue siendo un PDF válido).
    private fun writeTest() {
        val uri = testUri ?: return run { report = "Primero elige MDobe-prueba.pdf" }
        val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else null }
        if (name != "MDobe-prueba.pdf") return run { report = "Por seguridad solo pruebo con MDobe-prueba.pdf (has elegido $name)" }
        report = runCatching {
            val data = contentResolver.openInputStream(uri)!!.use { it.readBytes() }
            val out = data + "\n%MDobe prueba ${System.currentTimeMillis()}\n".toByteArray()
            contentResolver.openOutputStream(uri, "wt")!!.use { it.write(out) }
            "Escrito: ${data.size} → ${out.size} bytes. Mira ahora en el Mac si ha cambiado."
        }.getOrElse { "Error al escribir: ${it.javaClass.simpleName}: ${it.message}" }
        android.util.Log.i("MDobeTest", report)
    }

    private fun check(uri: Uri, via: String) {
        testUri = uri
        val name = runCatching {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else null }
        }.getOrNull() ?: uri.lastPathSegment
        val flags = runCatching {
            contentResolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_FLAGS), null, null, null)?.use { if (it.moveToFirst()) it.getInt(0) else null }
        }.getOrNull()
        val read = runCatching { contentResolver.openInputStream(uri)?.use { it.read(ByteArray(4)) } }.isSuccess
        // «rw» solo abre para escribir; no cambia nada del archivo.
        val write = runCatching { contentResolver.openFileDescriptor(uri, "rw")?.use { } ?: error("null") }
        report = """
            Vía: $via
            Archivo: $name
            Proveedor: ${uri.authority}
            Leer: ${if (read) "sí" else "NO"}
            Guardar encima: ${if (write.isSuccess) "SÍ ✅" else "NO ❌ (${write.exceptionOrNull()?.javaClass?.simpleName}: ${write.exceptionOrNull()?.message?.take(120)})"}
            Flags: $flags
        """.trimIndent()
        android.util.Log.i("MDobeTest", report)
    }
}
