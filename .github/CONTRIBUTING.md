# Cómo contribuir

Gracias por el interés en mejorar Autostart Manager. Esta guía resume lo básico para que tu aportación se pueda revisar y aceptar rápido.

## Antes de escribir código

- Para cambios grandes o que cambien el comportamiento actual, abre primero un issue (usando la plantilla de solicitud de función) para discutir el enfoque antes de invertir tiempo en la implementación.
- Para errores puntuales o mejoras pequeñas, puedes ir directo al *pull request*.

## Estilo de código

- Usa `shellcheck script/Autostart_Manager.sh` antes de enviar tu PR y revisa los avisos que introduzcas.
- Mantén el estilo ya presente: `local` para variables de función, comillas en las expansiones (`"$var"`), y `[[ ]]` en vez de `[ ]`.
- Los comentarios deben explicar decisiones no obvias (por qué se hace algo de cierta forma), no describir línea por línea lo que el código ya deja claro.
- Si tocas una de las cinco fuentes de autostart (usuario, sistema, systemd usuario/sistema, cron), prueba manualmente que activar y desactivar un elemento de ese tipo sigue funcionando antes de enviar el cambio.

## Probar tus cambios

No hay batería de tests automatizados (es un script interactivo basado en `zenity`), así que la prueba es manual:

1. Ejecuta el script en una sesión real de Linux Mint Cinnamon (o el entorno más parecido que tengas).
2. Verifica que la tabla carga sin errores en `stderr`.
3. Prueba activar y desactivar al menos un elemento del tipo que tu cambio afecta.
4. Si tu cambio toca `pkexec` o algo del sistema, confirma que solo se pide contraseña una vez por tanda de cambios.

## Enviar el Pull Request

- Haz el PR contra `main`.
- Describe qué cambia y por qué, y en qué entorno lo probaste (la plantilla de PR te guía en esto).
- PRs pequeños y enfocados en una sola cosa se revisan más rápido que PRs grandes que mezclan varios cambios.

## Reportar errores o proponer ideas

Usa las plantillas de issue del repositorio; se abren automáticamente al crear uno nuevo. Cuanto más contexto (distro, versión de `zenity`, pasos exactos), más rápido se puede diagnosticar.

Para temas de seguridad, no abras un issue público — consulta [`SECURITY.md`](SECURITY.md).
