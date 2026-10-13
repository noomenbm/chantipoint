# Questions client - ChantiPoint v0.1

Ce document interne sert à préparer une discussion de validation. Il ne constitue pas une approbation du client et ne doit pas être envoyé tel quel.

## Points compris comme établis pour la planification

Ces points sont traités comme des exigences rapportées pour la planification, mais ils devront être confirmés dans une spécification approuvée.

1. L'application ChantiPoint doit être en français.
2. Le pilote vise d'abord Android; iOS demeure une cible future.
3. L'application doit enregistrer les pointages manuels d'entrée et de sortie.
4. La localisation sert à fournir des indices liés au téléphone, sans prétendre prouver la présence physique ou la productivité de l'employé.
5. La paie est exclue de la V1; les totaux de sessions et l'export CSV opérationnel restent permis.
6. Un administrateur désigné examine initialement les sessions, anomalies, fermetures automatiques proposées et demandes de correction.
7. Le géorepérage demeure le candidat technique privilégié, sous réserve de faisabilité.
8. Les paramètres proposés sont un rayon de 100 à 150 m et un délai de grâce de 10 minutes après la réception fiable d'un événement de sortie.
9. Après 8 heures de session active, l'employé doit recevoir une notification avec `Terminer la session` et `Continuer la session`.
10. Les données GPS ou de géorepérage détaillées ont une conservation candidate d'environ 30 jours, sous réserve de validation.

## Décisions encore ouvertes

1. Confirmez-vous formellement que le modèle de surveillance proposé est acceptable pour la V1?
2. Souhaitez-vous autoriser une fermeture automatique de session si le téléphone semble quitter le chantier au-delà du délai de grâce? Si oui, quelles exceptions doivent empêcher cette fermeture automatique?
3. Le rayon final doit-il être 100 m, 150 m ou une autre tolérance après les tests de faisabilité?
4. Quelles preuves minimales doivent être exigées avant une fermeture automatique?
5. Que doit faire l'application si l'employé ne répond pas à la notification après 8 heures?
6. Quelle est la durée maximale absolue de surveillance autorisée pour une session anormalement longue?
7. Quelle procédure appliquer si la localisation est désactivée, si la permission est révoquée, si le téléphone est éteint ou si la connexion est perdue?
8. Qui peut approuver, refuser ou modifier une demande de correction de pointage?
9. Quels justificatifs l'employé doit-il fournir pour une correction de pointage?
10. Quelles attentes souhaitez-vous communiquer aux employés qui utilisent leur téléphone personnel: permissions de localisation, batterie, notifications, refus de permission, téléphone éteint ou localisation désactivée?
11. Qui sera responsable de l'avis aux employés, de la politique de surveillance, de l'EFVP et des validations légales ou RH?
12. Pendant combien de temps faut-il conserver séparément les données de localisation brutes, les sessions de travail, les demandes de correction, les décisions administratives, les journaux d'audit et les sauvegardes?
13. Les décisions administratives liées à des employés identifiables peuvent-elles être conservées plus longtemps que les données GPS brutes, et selon quelle politique approuvée?
14. Quels champs doivent apparaître dans l'export CSV de base?
15. Une seule personne gestionnaire doit-elle avoir accès aux données de localisation au lancement, ou faut-il prévoir plusieurs administrateurs dès la V1?
