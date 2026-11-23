"""Exercise blueprint deletion against real task middleware in a private fresh database."""

import argparse
from contextlib import redirect_stderr, redirect_stdout
import json
import os
import pathlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=pathlib.Path)
    parser.add_argument("runtime", type=pathlib.Path)
    parser.add_argument("postgres_bin", type=pathlib.Path)
    parser.add_argument("--expect-fixed", action="store_true")
    args = parser.parse_args()
    package = args.package.resolve()
    runtime = args.runtime.resolve()
    pg = args.postgres_bin.resolve()
    assert runtime.is_relative_to(pathlib.Path(tempfile.gettempdir()).resolve())
    assert runtime.is_dir() and not any(runtime.iterdir())
    runtime.chmod(0o700)
    os.environ.update(
        {
            "DJANGO_SETTINGS_MODULE": "authentik.root.settings",
            "AUTHENTIK_SECRET_KEY": "isolated-synthetic-fixture-only",
            "AUTHENTIK_POSTGRESQL__HOST": str(runtime / "socket"),
            "AUTHENTIK_POSTGRESQL__NAME": "fixture",
            "AUTHENTIK_POSTGRESQL__USER": "fixture",
            "AUTHENTIK_ERROR_REPORTING__ENABLED": "false",
            "AUTHENTIK_DISABLE_STARTUP_ANALYTICS": "true",
            "AUTHENTIK_DISABLE_UPDATE_CHECK": "true",
        }
    )
    os.chdir(package)
    import authentik

    assert pathlib.Path(authentik.__file__).resolve().is_relative_to(package)
    import django

    django.setup()
    from django.conf import settings
    from authentik.tasks.models import Task, TaskLog

    db = settings.DATABASES["default"]
    assert db["HOST"] == str(runtime / "socket")
    assert db["NAME"] == "fixture" and db["USER"] == "fixture"
    assert not os.access("/run/postgresql", os.R_OK)
    assert not os.access("/run/secrets", os.R_OK)
    print(
        json.dumps(
            {
                "loaded": True,
                "django": django.get_version(),
                "task_table": Task._meta.db_table,
                "tasklog_table": TaskLog._meta.db_table,
                "database": {
                    "host": db["HOST"],
                    "name": db["NAME"],
                    "user": db["USER"],
                },
            }
        ),
        flush=True,
    )
    from django.core.management import call_command
    from django.db import connections

    data = runtime / "data"
    socket = runtime / "socket"
    socket.mkdir(mode=0o700)
    started = False
    with (runtime / "bootstrap.log").open("w") as log:
        try:
            subprocess.run(
                [
                    str(pg / "initdb"),
                    "-D",
                    str(data),
                    "--no-locale",
                    "--encoding=UTF8",
                    "--auth=trust",
                    "--username=fixture",
                ],
                stdout=log,
                stderr=log,
                check=True,
            )
            subprocess.run(
                [
                    str(pg / "pg_ctl"),
                    "-D",
                    str(data),
                    "-l",
                    str(runtime / "postgres.log"),
                    "-o",
                    f"-k {socket} -h '' -c shared_buffers=32MB -c max_connections=20",
                    "-w",
                    "start",
                ],
                stdout=log,
                stderr=log,
                check=True,
            )
            started = True
            subprocess.run(
                [str(pg / "createdb"), "-h", str(socket), "-U", "fixture", "fixture"],
                stdout=log,
                stderr=log,
                check=True,
            )
            import psycopg
            from lifecycle.system_migrations.install_id import (
                Migration as InstallIdMigration,
            )

            with psycopg.connect(
                host=str(socket), dbname="fixture", user="fixture", autocommit=True
            ) as bootstrap_connection:
                with bootstrap_connection.cursor() as cursor:
                    InstallIdMigration(cursor, bootstrap_connection).run()
            settings.TEST = True
            with redirect_stdout(log), redirect_stderr(log):
                call_command(
                    "migrate_schemas", shared=True, interactive=False, verbosity=0
                )
            settings.TEST = False
            print(
                json.dumps(
                    {
                        "synthetic_migrations": "passed",
                        "task_rows": Task.objects.count(),
                        "tasklog_rows": TaskLog.objects.count(),
                    }
                ),
                flush=True,
            )
            from django.db import transaction
            from dramatiq import actor, get_broker
            from dramatiq.broker import MessageProxy
            from authentik.blueprints.models import (
                BlueprintInstance,
                BlueprintInstanceStatus,
            )
            from authentik.blueprints.v1.tasks import apply_blueprint
            from authentik.core.models import Group
            from authentik.tenants.utils import get_current_tenant

            tenant = get_current_tenant()
            tenant.activate()
            broker = get_broker()
            broker.middleware = [
                m for m in broker.middleware if type(m).__name__ != "MetricsMiddleware"
            ]

            @actor(actor_name="isolated_fk_control", queue_name="isolated_fk_control")
            def control():
                pass

            with transaction.atomic():
                rolled_back = control.send()
                assert Task.objects.filter(message_id=rolled_back.message_id).exists()
                transaction.set_rollback(True)
            assert not Task.objects.filter(message_id=rolled_back.message_id).exists()
            consumer = broker.consume(control.queue_name, timeout=100)
            try:
                assert consumer._consume_one(rolled_back.message_id) is None
            finally:
                consumer.close()
            from concurrent.futures import ThreadPoolExecutor
            from django.db import IntegrityError
            from authentik.blueprints.v1.tasks import clear_failed_blueprints
            from authentik.tasks.middleware import TaskLogMiddleware

            def run_cleanup():
                try:
                    tenant.activate()
                    with connections["default"].cursor() as cursor:
                        cursor.execute("SET statement_timeout = 5000")
                    clear_failed_blueprints.fn()
                finally:
                    connections.close_all()

            for iteration in range(3):
                broken = BlueprintInstance.objects.create(
                    name=f"Isolated missing blueprint {iteration}",
                    path=f"isolated-missing-{iteration}.yaml",
                    enabled=True,
                )
                queued = apply_blueprint.send_with_options(
                    args=(broken.pk,), rel_obj=broken
                )
                consumer = broker.consume(apply_blueprint.queue_name, timeout=100)
                try:
                    decoded = consumer._consume_one(queued.message_id)
                    assert decoded is not None
                    message = MessageProxy(decoded)
                    task = message.options["task"]
                    assert Task.objects.filter(pk=task.pk).exists()
                    with ThreadPoolExecutor(max_workers=1) as executor:
                        executor.submit(run_cleanup).result(timeout=10)
                    assert not BlueprintInstance.objects.filter(pk=broken.pk).exists()
                    if args.expect_fixed:
                        from datetime import timedelta
                        from django.utils.timezone import now

                        assert Task.objects.filter(pk=task.pk).exists()
                        broker.emit_before("process_message", message)
                        assert TaskLog.objects.filter(
                            task=task, event="Task is being processed"
                        ).exists()
                        result = apply_blueprint.fn(*message.args, **message.kwargs)
                        broker.emit_after(
                            "process_message", message, result=result, exception=None
                        )
                        consumer.ack(message)
                        task.refresh_from_db()
                        assert task.state == "done"
                        assert TaskLog.objects.filter(
                            task=task, event="Task finished processing without errors"
                        ).exists()
                        assert TaskLog.objects.filter(
                            task=task, log_level="warning"
                        ).exists()
                        assert not TaskLog.objects.filter(
                            task=task, log_level="error"
                        ).exists()
                        old = now() - timedelta(days=32)
                        Task.objects.filter(pk=task.pk).update(
                            mtime=old, result_expiry=old
                        )
                        consumer.task_purge_last_run = old
                        consumer._auto_purge()
                        assert not Task.objects.filter(pk=task.pk).exists()
                        assert not TaskLog.objects.filter(task_id=task.pk).exists()
                        print(
                            json.dumps(
                                {
                                    "cleanup_race_fixed": True,
                                    "iteration": iteration + 1,
                                    "normal_retention_passed": True,
                                }
                            ),
                            flush=True,
                        )
                        continue
                    assert not Task.objects.filter(pk=task.pk).exists()
                    try:
                        TaskLogMiddleware().before_process_message(broker, message)
                    except IntegrityError as exc:
                        assert exc.__cause__.sqlstate == "23503"
                        constraint = exc.__cause__.diag.constraint_name
                        assert (
                            constraint
                            == "authentik_tasks_task_task_id_a82f0835_fk_authentik"
                        )
                    else:
                        raise AssertionError(
                            "Expected the observed before-process FK failure"
                        )
                    print(
                        json.dumps(
                            {
                                "cleanup_race_reproduced": True,
                                "iteration": iteration + 1,
                                "sqlstate": "23503",
                                "constraint": constraint,
                            }
                        ),
                        flush=True,
                    )
                finally:
                    consumer.close()
            print(json.dumps({"rollback_consumer_control": "passed"}), flush=True)
            content = "version: 1\nmetadata:\n  name: Isolated FK fixture\nentries:\n  - model: authentik_core.group\n    identifiers:\n      name: isolated-fk-fixture\n    attrs:\n      name: isolated-fk-fixture\n"
            instance = BlueprintInstance.objects.create(
                name="Isolated FK fixture", content=content, enabled=True
            )
            queued = apply_blueprint.send_with_options(
                args=(instance.pk,), rel_obj=instance
            )
            consumer = broker.consume(apply_blueprint.queue_name, timeout=100)
            try:
                decoded = consumer._consume_one(queued.message_id)
                assert decoded is not None
                message = MessageProxy(decoded)
                task = message.options["task"]
                assert Task.objects.filter(pk=task.pk).exists()
                broker.emit_before("process_message", message)
                assert TaskLog.objects.filter(
                    task=task, event="Task is being processed"
                ).exists()
                result = apply_blueprint.fn(*message.args, **message.kwargs)
                broker.emit_after(
                    "process_message", message, result=result, exception=None
                )
                consumer.ack(message)
                task.refresh_from_db()
                assert task.state == "done"
                instance.refresh_from_db()
                print(
                    json.dumps(
                        {
                            "blueprint_status": instance.status,
                            "events": list(
                                TaskLog.objects.filter(task=task).values_list(
                                    "event", flat=True
                                )
                            ),
                        }
                    ),
                    flush=True,
                )
                assert instance.status == BlueprintInstanceStatus.SUCCESSFUL
                assert Group.objects.filter(name="isolated-fk-fixture").exists()
                assert Task.objects.filter(pk=task.pk).exists()
                assert TaskLog.objects.filter(
                    task=task, event="Task finished processing without errors"
                ).exists()
                assert not TaskLog.objects.filter(task=task, log_level="error").exists()
                print(
                    json.dumps(
                        {
                            "actual_blueprint_lifecycle": "passed",
                            "tasklog_rows": TaskLog.objects.filter(task=task).count(),
                            "production_failure_reproduced": False,
                        }
                    ),
                    flush=True,
                )
            finally:
                consumer.close()
        except Exception as exc:
            log.flush()
            print(
                json.dumps(
                    {"synthetic_migrations": "failed", "type": type(exc).__name__}
                ),
                flush=True,
            )
            print((runtime / "bootstrap.log").read_text()[-6000:], flush=True)
            raise
        finally:
            connections.close_all()
            if started:
                subprocess.run(
                    [
                        str(pg / "pg_ctl"),
                        "-D",
                        str(data),
                        "-m",
                        "immediate",
                        "-w",
                        "stop",
                    ],
                    stdout=log,
                    stderr=log,
                    check=True,
                )


if __name__ == "__main__":
    main()
